// koru/native kbd — the 8042 PS/2 keyboard provider, koruos/input's
// koru-native mechanism.
//
// IRQ1 (vec 0x21) lands here from user.zig's dispatch; each scancode byte
// is pushed to a small ring that koruos_input_poll drains. Set-1 codes
// are passed through raw — make = bit7 clear, break = set — and E0 is
// folded into the code as bit8, so callers never see the prefix byte.
// No charmap, no keymap: translation is a layer above the seam.
//
// init() drains the controller's stale output byte and unmasks IRQ1 at
// the PIC — the honest first shape is "interrupt-paced ring, poll to
// read"; sleeping on input is the wait-queue rung, deliberately not a
// faked blocking call here.

const mouse = @import("mouse");
const comp = @import("comp");

extern fn koru_irq_unmask(irq: u8) void;
extern var stdout: ?*anyopaque;
extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern fn koru_input_wake() callconv(.c) void;

const DATA: u16 = 0x60;
const STATUS: u16 = 0x64;

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
        : .{ .memory = true });
}
fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
        : .{ .memory = true });
}

fn say(s: [*:0]const u8) void {
    _ = fputs(s, stdout);
}

var ring: [64]u8 = undefined;
var head: usize = 0;
var tail: usize = 0;
var e0_pending: bool = false;
var drops: u64 = 0;

// ---- console input: the read(0) path --------------------------------------
// A second ring, ASCII bytes this time — the scancode ring above serves
// koruos/input (raw make/break is that contract); a child's read() wants
// *characters*. Set-1 makes map through two glyph tables — shift state
// (make 2A/36, break AA/B6) selects which one answers. Caps lock stays
// unmodeled: honest, not silently wrong.
const SET1: [58]u8 = .{ 0, 0, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', 0x08, 0,
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0,
    'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0, '\\',
    'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/', 0, '*', 0, ' ' };
const SET1_SHIFT: [58]u8 = .{ 0, 0, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', 0x08, 0,
    'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', '\n', 0,
    'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', 0, '|',
    'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?', 0, '*', 0, ' ' };

var shift: bool = false;

var con: [256]u8 = undefined;
var chead: usize = 0;
var ctail: usize = 0;

// one controller byte into the scancode ring + the ASCII conin map.
// IRQ and the poll-drain both land here — the byte is the unit, not
// the path it arrived by.
pub fn feedByte(sc: u8) void {
    const next = (head + 1) % ring.len;
    if (next == tail) {
        drops += 1;
    } else {
        ring[head] = sc;
        head = next;
    }
    // console ring: shift make/break updates the state, other make-codes
    // map through the table it selects, dropped when full
    const code = sc & 0x7F;
    if (code == 0x2A or code == 0x36) {
        shift = (sc & 0x80) == 0;
    } else if (sc & 0x80 == 0 and code < SET1.len) {
        const ch = if (shift) SET1_SHIFT[code] else SET1[code];
        if (ch != 0) {
            const cn = (chead + 1) % con.len;
            if (cn != ctail) {
                con[chead] = ch;
                chead = cn;
            }
        }
    }
    koru_input_wake(); // a child input fd is ready — mark-only prod
}

// vec-0x21 path — called from user.zig's irq_exc_dispatch. Status bit5
// (AUX) names whose byte it is: an aux byte pending during a phantom
// IRQ1 belongs to the mouse packet assembler, not this ring.
pub fn irq() void {
    const st = inb(STATUS);
    if (st & 1 == 0) return; // no output byte — nothing of ours here
    const b = inb(DATA);
    if ((st & 0x20) != 0) {
        mouse.feedByte(b);
        return;
    }
    feedByte(b);
}

// is a console byte pending? — the under-mask recheck read(0) does
// before blocking, so a byte landing mid-check can't be slept past
pub fn conPending() bool {
    return ctail != chead;
}

// one pending console byte for read(0), or null — nonblocking pop
pub fn conByte() ?u8 {
    if (ctail == chead) return null;
    const ch = con[ctail];
    ctail = (ctail + 1) % con.len;
    return ch;
}

// polled console key for the no-IRQ text console — reads the 8042
// directly and maps set-1 makes through the same tables, without the
// rings or koru_input_wake (neither is safe before user.init). One
// scancode byte per call; returns the ASCII char or null.
pub fn pollChar() ?u8 {
    const st = inb(STATUS);
    if (st & 1 == 0) return null;
    // AUX check BEFORE consuming: an aux byte pending ahead of IRQ12's
    // handler must be LEFT in the output register — reading it here and
    // dropping it desyncs the mouse's 3-byte packet frame (wild dx/dy =
    // the T590 cursor-jump bug). IRQ12 is armed whenever aux streams,
    // so the byte is drained there a few instructions later.
    if (st & 0x20 != 0) return null; // aux/mouse byte — not ours, don't eat
    const b = inb(DATA);
    const code = b & 0x7F;
    if (code == 0x2A or code == 0x36) { // shift make/break updates state
        shift = (b & 0x80) == 0;
        return null;
    }
    if (b & 0x80 != 0 or code >= SET1.len) return null; // break / unmapped
    const ch = if (shift) SET1_SHIFT[code] else SET1[code];
    return if (ch != 0) ch else null;
}

// every byte the init conversation produces, logged for the screen —
// the raw dump shows live keys; this shows what the keyboard said while
// we were configuring it (FA/AA/resets/timeouts all visible).
var klog: [48]u8 = undefined;
var klogN: usize = 0;
fn klogByte(b: u8) void {
    if (klogN < klog.len) {
        klog[klogN] = b;
        klogN += 1;
    }
}
pub fn klogAt(i: usize) u8 {
    return if (i < klogN) klog[i] else 0;
}
pub fn klogLen() usize {
    return klogN;
}

// raw 8042 output byte for the scancode-set diagnostic — no filtering,
// no tables, no aux check. Every byte the controller emits surfaces:
// kbd make/break, E0 prefixes, aux packets — full transparency.
pub fn pollRaw() ?u8 {
    const st = inb(STATUS);
    if (st & 1 == 0) return null;
    return inb(DATA);
}
pub fn statusRaw() u8 {
    return inb(STATUS);
}
// controller config byte: 0x20 to the command port (0x64), response on
// 0x60. bit4 = keyboard interface inhibited — the leading suspect for
// "commands ACK but scan bytes never arrive".
pub fn ccbRead() u8 {
    var i: usize = 0;
    while (inb(STATUS) & 0x02 != 0) : (i += 1) {
        if (i > 1000000) return 0xEE;
    }
    outb(STATUS, 0x20);
    i = 0;
    while (i < 200000) : (i += 1) {
        if (pollRaw()) |b| return b;
    }
    return 0xEE;
}

// console-mode keyboard bring-up — no IRQs, just the 8042 data port.
// Real init sequence, ACK-synchronized: reset (0xFF) -> FA + AA(BAT ok),
// then scancode-set, enable-scanning, LEDs. The earlier fire-and-forget
// version left the keyboard in whatever state the loader left — it ACKed
// commands (the FA on screen) but never scanned, so keys produced nothing.
pub fn consoleInit() void {
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        if (inb(STATUS) & 1 == 0) break;
        _ = inb(DATA);
    }
    ksend(0xFF);          // reset — keyboard re-runs its BAT
    _ = kawait(0xFA);     // ACK
    _ = kawait(0xAA);     // BAT OK (0xFC = failed self-test)
    ksend(0xF0); _ = kawait(0xFA); ksend(0x01); _ = kawait(0xFA); // set-1
    ksend(0xF4); _ = kawait(0xFA); // enable scanning
    ksend(0xED); _ = kawait(0xFA); ksend(0x00); _ = kawait(0xFA); // LEDs off
}
fn ksend(b: u8) void {
    var i: usize = 0;
    while (inb(STATUS) & 0x02 != 0) : (i += 1) {
        if (i > 1000000) return;
    }
    outb(DATA, b);
}
// read output bytes until `want` shows up or we give up — returns the
// byte seen (or 0 on timeout) so callers/tests can inspect the stream.
fn kawait(want: u8) u8 {
    var i: usize = 0;
    while (i < 200000) : (i += 1) {
        if (inb(STATUS) & 1 != 0) {
            const b = inb(DATA);
            klogByte(b);
            if (b == want) return b;
        }
    }
    return 0;
}

// ---- shared 8042 primitives for the aux/mouse probe (M4) -------------------
// The aux channel shares this controller — mouse.zig's bring-up reuses
// these exact proven inb/outb/status-bit waits rather than duplicating
// (and mis-timing) them. Command bytes -> 0x64, data bytes -> 0x60.

// write a controller command byte to port 0x64, IBF-safe (same wait
// ksend uses: bit1 set = input buffer full = keep waiting).
pub fn ctlWrite(cmd: u8) void {
    var i: usize = 0;
    while (inb(STATUS) & 0x02 != 0) : (i += 1) {
        if (i > 1000000) return;
    }
    outb(STATUS, cmd);
}

// write a data byte to port 0x60 (device-bound), IBF-safe.
pub fn dataWrite(b: u8) void {
    var i: usize = 0;
    while (inb(STATUS) & 0x02 != 0) : (i += 1) {
        if (i > 1000000) return;
    }
    outb(DATA, b);
}

// is an output byte latched? (status bit0 = OBF)
pub fn outAvail() bool {
    return inb(STATUS) & 1 != 0;
}
// read one output byte from 0x60 — caller MUST have seen outAvail first.
pub fn readOut() u8 {
    return inb(DATA);
}
// flush every latched output byte — call BEFORE a command whose response
// we want to be the *next* byte, so a stale scancode can't be mistaken
// for the reply (the 8042diag selftest-bad bug: read-first-byte grabbed a
// leftover byte instead of awaiting the real 0x55).
pub fn drainOut() void {
    var guard: usize = 0;
    while (outAvail() and guard < 64) : (guard += 1) {
        _ = readOut();
    }
}

pub fn init() void {
    // drain a stale byte the firmware/loader may have left in the buffer
    while (inb(STATUS) & 1 != 0) _ = inb(DATA);
    koru_irq_unmask(1);
    say("kbd: 8042 online, IRQ1 unmasked\n");
}

// the seam's event record — mouse.zig shares this exact type (one
// owner, one layout), so a popped event assigns directly.
pub const InEv = extern struct {
    kind: u32,
    code: u32,
    pressed: u32,
    dx: i32,
    dy: i32,
};

// would a pop yield an event? — non-destructive scan mirroring the
// decode loop: every byte that isn't a bare E0/E1 prefix decodes to
// one InEv, so readiness is "a decodable byte is latched".
fn evPending() bool {
    var t = tail;
    while (t != head) {
        const sc = ring[t];
        t = (t + 1) % ring.len;
        if (sc != 0xE0 and sc != 0xE1) return true;
    }
    return false;
}

// pending() — non-destructive readiness across both rings; the seam's
// POLLIN predicate and block/race recheck for a child input fd.
pub export fn koruos_input_pending() callconv(.c) u8 {
    if (evPending()) return 1;
    return if (mouse.pending() != 0) 1 else 0;
}

pub export fn koruos_input_poll(out: *InEv) callconv(.c) u8 {
    // drain-on-poll: a byte latched while IRQs were masked (or an edge
    // lost to a phantom interrupt) still surfaces — the ring is the
    // contract, not the edge. Bit5 routes it: aux bytes assemble mouse
    // packets, anything else is a scancode. Then device order, not
    // arrival order: mouse events first, keys after — a merged
    // timestamped stream is the compositor's refinement, not v0's lie.
    const st = inb(STATUS);
    if (st & 1 != 0) {
        const b = inb(DATA);
        if ((st & 0x20) != 0) mouse.feedByte(b) else feedByte(b);
    }
    if (mouse.pop()) |ev| {
        // motion fan-out: the compositor owns pointer position and sees
        // every delta; the client still gets the raw event (v0 — focus
        // delivery to surfaces is a later rung, named not faked).
        if (ev.kind == 3) {
            comp.feedMotion(ev.dx, ev.dy);
            comp.flush();
        }
        out.* = ev;
        return 1;
    }
    while (tail != head) {
        const sc = ring[tail];
        tail = (tail + 1) % ring.len;
        if (sc == 0xE0) {
            e0_pending = true;
            continue;
        }
        if (sc == 0xE1) continue; // pause's 3-byte seq — unmodeled, skipped
        var code: u32 = sc & 0x7F;
        if (e0_pending) code |= 0x100;
        e0_pending = false;
        out.* = .{ .kind = 1, .code = code, .pressed = if (sc & 0x80 == 0) 1 else 0, .dx = 0, .dy = 0 };
        return 1;
    }
    return 0;
}
