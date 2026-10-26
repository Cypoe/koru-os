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

extern fn koru_irq_unmask(irq: u8) void;
extern var stdout: ?*anyopaque;
extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;

const DATA: u16 = 0x60;
const STATUS: u16 = 0x64;

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
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
