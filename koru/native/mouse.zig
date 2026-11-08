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

const kbd = @import("kbd");

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
    if (!waitIn()) return false;
    outb(STATUS, 0xD4);
    if (!waitIn()) return false;
    outb(DATA, cmd);
    var i: u32 = 0;
    while (i < 200_000) : (i += 1) {
        const st = inb(STATUS);
        if ((st & 1) == 0) continue;
        const b = inb(DATA); // bit5 belongs to the status read before the drain
        if ((st & AUX_BYTE) == 0) {
            kbd.feedByte(b);
            continue;
        }
        return b == 0xFA;
    }
    return false;
}

// ---- 8042 controller probe helpers (M4 diag) --------------------------------
// Controller commands go to port 0x64, data to 0x60. sendCtl issues a
// command byte; readCtlByte drains one output byte with a bounded wait.
fn sendCtl(cmd: u8) bool {
    if (!waitIn()) return false;
    outb(STATUS, cmd);
    return true;
}
fn readCtlByte() ?u8 {
    var i: u32 = 0;
    while (i < 200_000) : (i += 1) {
        const st = inb(STATUS);
        if ((st & 1) != 0) {
            const b = inb(DATA);
            if ((st & AUX_BYTE) == 0) return b; // kbd-class byte is ours here
            // aux byte during probe — route to assembler, keep waiting
            feedByte(b);
        }
    }
    return null;
}

// Full 8042 aux bring-up probe. Order matters on some ECs: pulse the aux
// channel (0xA7 disable / 0xA8 enable) to reset it, THEN fix CCB, THEN
// handshake the device. Records every step into st_* for the diag.
pub fn init() void {
    init_tried = true;
    // The handshake races the armed IRQ handlers: a controller reply
    // lands in the output buffer as a *kbd-class* byte and raises IRQ1,
    // whose handler would consume it while we poll. i8042 discipline —
    // run command sequences with delivery off; the byte still latches
    // in OBF for our own read, it just can't be stolen mid-wait.
    cli();
    defer sti();
    if (!waitIn()) {
        say("mouse: controller input buffer never emptied — refusing\n");
        return;
    }

    // STEP 1 — controller self-test 0xAA. A live 8042 answers 0x55.
    // If this fails the keyboard would be dead too, but record it anyway.
    if (sendCtl(0xAA)) {
        st_selftest = readCtlByte() orelse 0xEE;
    } else {
        st_selftest = 0xEE;
    }
    say("mouse: 8042 selftest="); koru_putdec(st_selftest); say("\n");

    // STEP 2 — read CCB (0x20) so we know the controller's current aux
    // gating before we touch it.
    if (sendCtl(0x20)) {
        st_ccb = readCtlByte() orelse 0xEE;
    } else {
        st_ccb = 0xEE;
    }
    say("mouse: CCB="); koru_putdec(st_ccb); say("\n");

    // STEP 3 — pulse the aux channel: 0xA7 disable then 0xA8 enable.
    // Some ECs latch the aux port in a wedged state; a disable/enable
    // cycle is the documented reset. st_auxen records the enable took.
    _ = sendCtl(0xA7);
    _ = readCtlByte(); // drain any response (usually none for A7)
    st_auxen = if (sendCtl(0xA8)) 1 else 0;
    _ = readCtlByte(); // drain
    say("mouse: aux pulse A7/A8 auxen="); koru_putdec(st_auxen); say("\n");

    // STEP 4 — CCB: set bit1 (aux IRQ), clear bit5 (aux clock disable) —
    // the kbd bits belong to kbd. Uses the value read in step 2 if sane.
    var ccb = st_ccb;
    if (ccb == 0xEE) ccb = 0x45; // sane default: kbd irq on, translation on
    ccb |= 0x02;
    ccb &= ~@as(u8, 0x20);
    if (!sendCtl(0x60)) {
        say("mouse: controller busy before CCB write — refusing\n");
        return;
    }
    if (!waitIn()) {
        say("mouse: controller busy on CCB data — refusing\n");
        return;
    }
    outb(DATA, ccb);

    // STEP 5 — device handshake: 0xF6 set defaults + 0xF4 enable
    // reporting. auxWrite returns true only on a 0xFA ACK from the device.
    if (!auxWrite(0xF6) or !auxWrite(0xF4)) {
        say("mouse: device refused enable — no pointer input\n");
        // STEP 6 (diagnostic) — poll 0x60 anyway for a window: maybe the
        // device streams unsolicited packets even without the enable ACK.
        st_pollbytes = pollWindow();
        say("mouse: post-refuse poll bytes="); koru_putdec(st_pollbytes); say("\n");
        return;
    }
    aux_online = true; // device ACK'd both commands -> detected+enabled

    // STEP 6 — post-enable poll: catch any bytes the device already
    // queued, and prove the data port drains even if IRQ12 is masked.
    st_pollbytes = pollWindow();
    say("mouse: post-enable poll bytes="); koru_putdec(st_pollbytes); say("\n");

    koru_irq_unmask(12);
    irq_armed = true;
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
