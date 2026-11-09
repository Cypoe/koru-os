// koru/native mouse — the 8042 aux-channel PS/2 mouse provider.
//
// IRQ12 (vec 0x2C) lands here from user.zig's dispatch. The aux channel
// is the same 8042 the kbd owns — controller command port is shared —
// so each provider touches only its own bits: kbd sets CCB bit0, this
// one sets CCB bit1 and clears bit5 (aux clock enable), nobody disables
// the other's channel. Bytes are told apart by status bit5 (AUX flag) —
// the flag, not the IRQ, is the routing fact: a stray byte drained on
// poll goes to whoever bit5 names.
//
// Packets are the standard 3-byte PS/2 frame: byte0 carries button bits
// (0=L,1=R,2=M), the always-1 sync bit3, sign + overflow flags; bytes
// 1-2 are dx/dy. Decoded events go to a small ring drained by
// koruos_input_poll through pop() — button events carry X-style codes
// (1=L,2=M,3=R) so both arms' callers see the same vocabulary (the
// iface's own rule), motion carries raw device deltas.

const std = @import("std");
const kbd = @import("kbd");
const net = @import("net");

extern fn koru_irq_unmask(irq: u8) void;
extern var stdout: ?*anyopaque;
extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern fn koru_input_wake() callconv(.c) void;
extern fn koru_putdec(v: u64) void;

const DATA: u16 = 0x60;
const STATUS: u16 = 0x64;
const AUX_BYTE: u8 = 0x20; // status bit5 — output byte came from aux

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
        : .{ .memory = true });
}
fn outb(port: u16, v: u8) void {
    asm volatile ("outb %[v], %[port]"
        :
        : [v] "{al}" (v),
          [port] "N{dx}" (port),
        : .{ .memory = true });
}
fn cli() void {
    asm volatile ("cli");
}
fn sti() void {
    asm volatile ("sti");
}
fn say(s: [*:0]const u8) void {
    _ = fputs(s, stdout);
}

// sayU — dual-write one formatted line: serial (fputs) AND the UDP
// mirror. Real-T590 debugging happens over the wire, so every runtime
// diagnostic token MUST take the mirror path or it is invisible there
// (same discipline as xhci.zig's say).
fn sayU(comptime fmt: []const u8, args: anytype) void {
    var buf: [192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    buf[s.len] = 0;
    _ = fputs(@ptrCast(&buf), stdout);
    net.mirror(s);
}

// ---- event ring -----------------------------------------------------------

var ring: [64]kbd.InEv = undefined;
var head: usize = 0;
var tail: usize = 0;
var drops: u64 = 0;

// ---- M4 diagnostic state ---------------------------------------------------
// init() outcome + cumulative counters + per-step handshake results,
// exposed for the 'mouse' command so a silent cursor splits "aux never
// streamed" from "sprite not visible". step* fields are the 8042 probe.
var aux_online: bool = false; // device ACK'd enable -> detected+online
var irq_armed: bool = false;  // IRQ12 unmasked at the IOAPIC/PIC
var init_tried: bool = false;
var st_selftest: u8 = 0;   // 0xAA result byte (0x55 = controller OK)
var st_ccb: u8 = 0;        // CCB read back via 0x20
var st_auxen: u8 = 0;      // 0xA8 aux-enable accepted (1) or refused (0)
var st_pollbytes: u32 = 0; // bytes seen polling 0x60 after enable
var st_f6: u8 = 0;         // 0xF6 reset+disable ACK (0xFA = accepted)
var st_variant: u8 = 0;    // TP_READ_ID variant (0 = not a TrackPoint)
var st_firmware: u8 = 0;   // TP_READ_ID firmware byte
var st_por: u8 = 0;        // 0=ok(AA 00) 1=fail 2=skipped(non-IBM) 3=no-TP
var st_cfg: u8 = 0;        // rate/res/scale ACK count (of 3)

// diagnostic snapshot for the shell — all fields the oracle needs.
pub const Diag = extern struct {
    tried: u32,
    aux_online: u32,
    irq_armed: u32,
    packets: u64,
    desyncs: u64,
    overflows: u64,
    drops: u64,
    selftest: u32,
    ccb: u32,
    auxen: u32,
    pollbytes: u32,
    f6: u32,
    variant: u32,
    firmware: u32,
    por: u32,
    cfg: u32,
};
pub fn diag() Diag {
    return .{
        .tried = @intFromBool(init_tried),
        .aux_online = @intFromBool(aux_online),
        .irq_armed = @intFromBool(irq_armed),
        .packets = packets,
        .desyncs = desyncs,
        .overflows = overflows,
        .drops = drops,
        .selftest = st_selftest,
        .ccb = st_ccb,
        .auxen = @intFromBool(st_auxen != 0),
        .pollbytes = st_pollbytes,
        .f6 = st_f6,
        .variant = st_variant,
        .firmware = st_firmware,
        .por = st_por,
        .cfg = st_cfg,
    };
}

fn push(ev: kbd.InEv) void {
    const next = (head + 1) % ring.len;
    if (next == tail) {
        drops += 1;
        return;
    }
    ring[head] = ev;
    head = next;
    koru_input_wake(); // a child input fd is ready — mark-only prod
}

// pending — IRQ-safe readiness for the seam's poll predicate and a
// blocked child reader's race recheck (peek, not pop).
pub fn pending() u8 {
    return if (tail != head) 1 else 0;
}

// one decoded event for the seam, or null — nonblocking pop
pub fn pop() ?kbd.InEv {
    if (tail == head) return null;
    const ev = ring[tail];
    tail = (tail + 1) % ring.len;
    return ev;
}

// ---- packet assembler -----------------------------------------------------

var pkt: [3]u8 = .{ 0, 0, 0 };
var pi: usize = 0;
var prev_btns: u8 = 0;
var desyncs: u64 = 0;
var overflows: u64 = 0;
var packets: u64 = 0;

fn sign9(v: u8, neg: bool) i32 {
    const w: i32 = v;
    return if (neg) w - 256 else w;
}

// feed a raw byte — bit3 of byte0 is the sync flag; a frame arriving
// mid-stream slides until it resyncs, counted not silently absorbed.
pub fn feedByte(b: u8) void {
    if (pi == 0 and (b & 0x08) == 0) {
        desyncs += 1;
        return;
    }
    pkt[pi] = b;
    pi += 1;
    if (pi < 3) return;
    pi = 0;
    packets += 1;
    const btns = pkt[0] & 0x07;
    const ovf = (pkt[0] & 0xC0) != 0;
    if (ovf) overflows += 1;
    const dx = if (ovf) 0 else sign9(pkt[1], (pkt[0] & 0x10) != 0);
    // PS/2 Y is positive-up (device space); the seam's contract is
    // evdev-shaped — positive-dy means DOWN, surface-coordinate space.
    // The negate lives here, at the provider, so every reader of the
    // ring sees the same convention the compositor's cursor follows.
    const dy = if (ovf) 0 else -sign9(pkt[2], (pkt[0] & 0x20) != 0);
    if (dx != 0 or dy != 0)
        push(.{ .kind = 3, .code = 0, .pressed = 0, .dx = dx, .dy = dy });
    // button edges — a packet reports state, the seam wants transitions
    const codes = [3]u32{ 1, 3, 2 }; // ps2 bit0=L,1=R,2=M -> x11 1=L,3=R,2=M
    var i: u3 = 0;
    while (i < 3) : (i += 1) {
        const now = (btns >> i) & 1;
        const was = (prev_btns >> i) & 1;
        if (now != was)
            push(.{ .kind = 2, .code = codes[i], .pressed = now, .dx = 0, .dy = 0 });
    }
    prev_btns = btns;
}

// vec-0x2C path — called from user.zig's irq_exc_dispatch. Reads the byte
// the controller has; if it arrived without the aux flag it isn't ours —
// route it to the kbd rather than eat it.
pub export fn mouse_irq() callconv(.c) void {
    const st = inb(STATUS);
    if (st & 1 == 0) return;
    const b = inb(DATA);
    if ((st & AUX_BYTE) != 0) feedByte(b) else kbd.feedByte(b);
}

// ---- init -----------------------------------------------------------------

fn waitOut() bool {
    var i: u32 = 0;
    while (i < 200_000) : (i += 1) {
        if ((inb(STATUS) & 1) != 0) return true;
    }
    return false;
}

// status bit1 is input-buffer-full — a command or data byte written
// while the controller still holds one is dropped, on QEMU just the
// same as on real silicon. Every write waits for it first.
fn waitIn() bool {
    var i: u32 = 0;
    while (i < 200_000) : (i += 1) {
        if ((inb(STATUS) & 2) == 0) return true;
    }
    return false;
}

// write a byte to the aux device: 0xD4 prefixes "next data byte is for
// the mouse". Waits for the ACK; a byte arriving without the aux flag
// mid-wait is routed to the kbd, not eaten — the channels share the
// output port, not the bytes.
fn auxWrite(cmd: u8) bool {
    return auxSendByte(cmd);
}

// auxSendByte — one device-bound byte with its own 0xD4 prefix and ACK
// wait (the 8042 routes exactly one byte per prefix). NAK (0xFE) gets one
// resend, error (0xFC) and timeout fail; unexpected aux bytes mid-wait
// are dropped the way Linux's ps2_handle_ack drops them. This is the
// per-byte primitive every multi-byte command below is built on —
// Linux's ps2_do_sendbyte, minus the scheduler.
fn auxSendByte(b: u8) bool {
    var attempt: u32 = 0;
    while (attempt < 2) : (attempt += 1) {
        if (!waitIn()) return false;
        outb(STATUS, 0xD4);
        if (!waitIn()) return false;
        outb(DATA, b);
        var i: u32 = 0;
        while (i < 400_000) : (i += 1) {
            const st = inb(STATUS);
            if ((st & 1) == 0) continue;
            const r = inb(DATA); // bit5 belongs to the status read before the drain
            if ((st & AUX_BYTE) == 0) {
                kbd.feedByte(r);
                continue;
            }
            if (r == 0xFA) return true;  // ACK
            if (r == 0xFE) break;        // NAK — resend the byte once
            if (r == 0xFC) return false; // device error
            // other aux byte while awaiting ACK — drop, keep waiting
        }
    }
    return false;
}

// auxCollect — read `dst.len` raw AUX-flagged response bytes. Unlike the
// ACK wait these are command RESULTS, not handshakes: Linux stores them
// verbatim into cmdbuf (no FA filtering). Non-aux bytes route to kbd.
// The long timeout covers POR's self-test, which can take ~500ms.
fn auxCollect(dst: []u8) bool {
    for (dst) |*p| {
        var got = false;
        var i: u32 = 0;
        while (i < 1_500_000) : (i += 1) {
            const st = inb(STATUS);
            if ((st & 1) == 0) continue;
            const b = inb(DATA);
            if ((st & AUX_BYTE) == 0) {
                kbd.feedByte(b);
                continue;
            }
            p.* = b;
            got = true;
            break;
        }
        if (!got) return false;
    }
    return true;
}

// tpCmd — a TrackPoint command: command byte + parameter bytes each
// ACK'd individually (Linux MAKE_PS2_CMD semantics — send count lives in
// bits 12-15, result count in bits 8-11, command in bits 0-7), then
// `results.len` raw response bytes collected.
fn tpCmd(send: []const u8, results: []u8) bool {
    for (send) |b| {
        if (!auxSendByte(b)) return false;
    }
    return auxCollect(results);
}

// ---- TrackPoint command constants (linux trackpoint.h) ---------------------
const TP_COMMAND    = 0xE2; // prefix: next bytes are TP-register commands
const TP_READ_ID    = 0xE1; // device identification — bare command, no prefix
const TP_POR        = 0x7F; // power-on reset (param of TP_COMMAND)
const TP_WRITE_MEM  = 0x81; // write RAM location (param of TP_COMMAND)
const TP_EXT_BTN    = 0x4B; // extended button status (IBM variant only)
const TP_SENS       = 0x4A; // RAM loc: sensitivity
const TP_VARIANT_IBM = 0x01;

// power-on defaults (trackpoint.h TP_DEF_*) — written only when the
// device was NOT freshly POR'd, mirroring trackpoint_sync(in_power_on
// _state=false). Linux writes the full attr set for IBM and only
// sensitivity+press_to_select for other variants; the press_to_select
// toggle (read-modify-write via TP_TOGGLE 0x47) is deferred — its power-
// on default is already the sane one.
const TP_DEFAULTS = [_]struct { u8, u8 }{
    .{ TP_SENS,      0x80 }, // sensitivity
    .{ 0x60,         0x61 }, // speed
    .{ 0x4D,         0x06 }, // inertia
    .{ 0x57,         0x0A }, // reach
    .{ 0x58,         0xFF }, // draghys
    .{ 0x59,         0x14 }, // mindrag
    .{ 0x5C,         0x08 }, // thresh
    .{ 0x5A,         0xFF }, // upthresh
    .{ 0x5E,         0x26 }, // ztime
    .{ 0x5D,         0x87 }, // jenks curvature
    .{ 0x5F,         0x05 }, // drift time
};

// tpWrite — E2 81 <loc> <val>, every byte ACK'd, no results.
fn tpWrite(loc: u8, val: u8) bool {
    return tpCmd(&.{ TP_COMMAND, TP_WRITE_MEM, loc, val }, &.{});
}

// tpWriteDefaults — Linux's non-reset path. Non-IBM variants only expose
// sensitivity (trackpoint_is_attr_available); an IBM that refused POR
// gets the whole scalar table since its state is unknown.
fn tpWriteDefaults(ibm_por_failed: bool) u8 {
    var n: u8 = 0;
    if (!ibm_por_failed) {
        if (tpWrite(TP_SENS, 0x80)) n = 1;
        return n;
    }
    for (TP_DEFAULTS) |d| {
        if (tpWrite(d[0], d[1])) n += 1;
    }
    return n;
}

// readResp — the FIRST kbd-class output byte after a drained command.
// kbd.drainOut() runs before each controller command, so the next
// non-aux byte IS the response — no stale-byte contamination (the bug
// that made 8042diag report selftest-bad on a live controller). Aux
// bytes route to the packet assembler, real scancodes to kbd.feedByte.
fn readResp() u8 {
    var i: u32 = 0;
    while (i < 400_000) : (i += 1) {
        const st = kbd.statusRaw();
        if (st & 1 == 0) continue;
        const b = kbd.readOut();
        if ((st & AUX_BYTE) != 0) {
            feedByte(b);
            continue;
        }
        kbd.feedByte(b); // preserve any real scancode
        return b;
    }
    return 0xEE;
}

// Full 8042 aux bring-up, built on kbd.zig's proven primitives
// (ctlWrite/dataWrite/drainOut/statusRaw/readOut — the same IBF/OBF
// status-bit waits consoleInit uses). Order mirrors Linux psmouse:
// controller probe -> RESET_DIS(0xF6) -> TrackPoint detect (READ_ID,
// POR, default writes) -> rate/res/scale -> ENABLE(0xF4) -> IRQ12.
pub fn init() void {
    if (init_tried) return; // lazy path may meet an already-run boot init
    init_tried = true;
    // The handshake races the armed IRQ handlers: run the whole probe
    // with delivery off so a controller reply can't be stolen mid-wait.
    cli();
    defer sti();

    // STEP 1 — controller self-test 0xAA -> expect 0x55. Drain first so a
    // leftover byte can't be mistaken for the reply.
    kbd.drainOut();
    kbd.ctlWrite(0xAA);
    st_selftest = readResp();
    sayU("mouse: 8042 selftest={d}\n", .{st_selftest});

    // STEP 2 — read CCB (0x20): the controller's aux gating as found.
    // Validated: a legal CCB has bits 7 and 3 clear. A scancode or aux
    // byte beating the reply would be misread as the CCB — and writing
    // it back can set bit4 (kbd clock inhibit), which is exactly how the
    // T590 keyboard died after 'mouse'. Invalid replies are retried;
    // readResp already routed any real scancode to kbd.feedByte.
    var ccb: u8 = 0xEE;
    var ctries: u32 = 0;
    while (ctries < 3) : (ctries += 1) {
        kbd.drainOut();
        kbd.ctlWrite(0x20);
        const r = readResp();
        if ((r & 0x88) == 0) {
            ccb = r;
            break;
        }
    }
    st_ccb = ccb;
    sayU("mouse: CCB={d}\n", .{st_ccb});

    // STEP 3 — pulse the aux channel: 0xA7 disable / 0xA8 enable. These
    // produce no reply byte; drainOut clears any stray after each.
    kbd.ctlWrite(0xA7);
    kbd.drainOut();
    kbd.ctlWrite(0xA8);
    st_auxen = 1; // ctlWrite is IBF-safe fire-and-forget; enable latched
    kbd.drainOut();
    sayU("mouse: aux pulse A7/A8 auxen={d}\n", .{st_auxen});

    // STEP 4 — CCB write 0x60: bit1 aux-IRQ on; bits 4+5 (kbd/aux clock
    // inhibits) FORCED OFF — the sanitize means even a garbage CCB read
    // can never write bit4=1 back and kill the keyboard (the T590
    // regression). bit0 kbd-IRQ, bit6 translation, bit2 system stay
    // exactly as read. 0xF6/TP commands below are all auxSendByte —
    // each carries its own 0xD4 prefix, nothing reaches the kbd.
    var cw: u8 = if ((ccb & 0x88) != 0) 0x45 else ccb; // invalid -> sane base
    cw |= 0x02;
    cw &= ~@as(u8, 0x30);
    kbd.ctlWrite(0x60);
    kbd.dataWrite(cw);
    // readback verify — the write must land with the kbd clock enabled.
    // bit4 still set means the controller refused/misread: retry once
    // with a fully-known-good CCB (kbd+aux irq, system, translate).
    kbd.drainOut();
    kbd.ctlWrite(0x20);
    const wb = readResp();
    sayU("mouse: ccb wr={x} rb={x}\n", .{ cw, wb });
    if ((wb & 0x10) != 0) {
        kbd.ctlWrite(0x60);
        kbd.dataWrite(0x47);
        say("mouse: ccb bit4 stuck — rewrote 0x47\n");
    }

    // STEP 5 — RESET_DIS 0xF6: reset the device and hold reporting off
    // while we interrogate it (Linux psmouse_probe's second command —
    // warn-only there, so a NAK is recorded not fatal).
    st_f6 = if (auxSendByte(0xF6)) 0xFA else 0;
    sayU("mouse: f6 reset+disable ack={x}\n", .{st_f6});

    // STEP 6 — TrackPoint detect: TP_READ_ID is the bare 0xE1 command
    // (no 0xE2 prefix — that prefix is only for register commands), two
    // raw result bytes: variant then firmware. A valid variant is 1..6.
    st_por = 3; // default: no TrackPoint on this port
    var idr: [2]u8 = undefined;
    if (auxSendByte(TP_READ_ID) and auxCollect(&idr)) {
        if (idr[0] >= 1 and idr[0] <= 6) {
            st_variant = idr[0];
            st_firmware = idr[1];
            st_por = 2; // non-IBM default — POR only defined for IBM
            sayU("mouse: trackpoint variant={d} fw=0x{x:0>2}\n", .{ st_variant, st_firmware });
            net.mark("mouse:tp-id");
            var was_reset = false;
            if (st_variant == TP_VARIANT_IBM) {
                // POR: E2 7F -> expect AA 00 (trackpoint_power_on_reset)
                var por: [2]u8 = undefined;
                if (tpCmd(&.{ TP_COMMAND, TP_POR }, &por) and
                    por[0] == 0xAA and por[1] == 0x00)
                {
                    st_por = 0;
                    was_reset = true;
                    net.mark("mouse:tp-por-ok");
                } else {
                    st_por = 1;
                    net.mark("mouse:tp-por-fail");
                }
                sayU("mouse: tp por={d}\n", .{st_por});
            } else {
                net.mark("mouse:tp-por-skip"); // Linux never PORs non-IBM
            }
            // Not freshly reset -> write power-on defaults so RAM attrs
            // can't be in a weird state (trackpoint_sync, in_power_on
            // _state=false arm). A successful POR means defaults already
            // live — Linux writes nothing then. IBM-fail gets the full
            // table; other variants get sensitivity only, per Linux attr
            // availability.
            const w: u8 = if (was_reset) 0 else tpWriteDefaults(st_variant == TP_VARIANT_IBM);
            sayU("mouse: tp defaults written={d}\n", .{w});
            // IBM variant: extended button query (Linux reads TP_EXT_BTN
            // for BTN_MIDDLE capability; 3-button fallback = 0x33).
            if (st_variant == TP_VARIANT_IBM) {
                var btn: [1]u8 = undefined;
                if (tpCmd(&.{ TP_COMMAND, TP_EXT_BTN }, &btn))
                    sayU("mouse: tp ext-btn=0x{x:0>2}\n", .{btn[0]});
            }
        } else {
            net.mark("mouse:tp-id-none"); // answered but not a TP variant
        }
    } else {
        net.mark("mouse:tp-id-none");
    }

    // STEP 7 — standard mouse config (Linux psmouse_initialize for
    // non-PS2 protocols): SETRATE 100cps, SETRES code 3 (200 cpi),
    // SETSCALE11 — each byte ACK'd, failures tolerated (Linux ignores
    // them too). Then ENABLE 0xF4 -> the device starts streaming.
    st_cfg = 0;
    if (auxSendByte(0xF3) and auxSendByte(100)) st_cfg += 1; // SETRATE
    if (auxSendByte(0xE8) and auxSendByte(3)) st_cfg += 1;   // SETRES
    if (auxSendByte(0xE6)) st_cfg += 1;                      // SETSCALE11
    sayU("mouse: rate/res/scale ack={d}/3\n", .{st_cfg});

    if (!auxWrite(0xF4)) {
        net.mark("mouse:enable-refused");
        say("mouse: device refused enable — no pointer input\n");
        // diagnostic — poll 0x60 anyway: maybe the device streams
        // unsolicited packets even without the enable ACK.
        st_pollbytes = pollWindow();
        sayU("mouse: post-refuse poll bytes={d}\n", .{st_pollbytes});
        return;
    }
    aux_online = true; // device ACK'd enable -> detected+online
    net.mark("mouse:aux-online");

    // STEP 8 — post-enable poll: catch any bytes the device already
    // queued, and prove the data port drains even if IRQ12 is masked.
    st_pollbytes = pollWindow();
    sayU("mouse: post-enable poll bytes={d}\n", .{st_pollbytes});

    koru_irq_unmask(12);
    irq_armed = true;
    net.mark("mouse:irq12-armed");
    say("mouse: PS/2 aux online, IRQ12 unmasked\n");
}

// Bounded nonblocking drain of port 0x60 — counts bytes the aux channel
// has already latched, feeding any real packets to the assembler. Runs
// AFTER the handshake so unsolicited/enable-triggered traffic is seen
// even before IRQ12 is unmasked.
fn pollWindow() u32 {
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < 400_000) : (i += 1) {
        const st = inb(STATUS);
        if ((st & 1) != 0) {
            const b = inb(DATA);
            n += 1;
            if ((st & AUX_BYTE) != 0) feedByte(b) else kbd.feedByte(b);
        }
    }
    return n;
}
