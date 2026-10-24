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

// vec-0x21 path — called from user.zig's irq_exc_dispatch. Reads one byte
// if the controller has one; on a full ring the byte is dropped and
// counted, never silently overwritten.
pub fn irq() void {
    const st = inb(STATUS);
    if (st & 1 == 0) return; // no output byte — nothing of ours here
    const sc = inb(DATA);
    const next = (head + 1) % ring.len;
    if (next == tail) {
        drops += 1;
        return;
    }
    ring[head] = sc;
    head = next;
}

pub fn init() void {
    // drain a stale byte the firmware/loader may have left in the buffer
    while (inb(STATUS) & 1 != 0) _ = inb(DATA);
    koru_irq_unmask(1);
    say("kbd: 8042 online, IRQ1 unmasked\n");
}

const InEv = extern struct {
    kind: u32,
    code: u32,
    pressed: u32,
    dx: i32,
    dy: i32,
};

pub export fn koruos_input_poll(out: *InEv) callconv(.c) u8 {
    // drain-on-poll: a byte latched while IRQ1 was masked (or an edge lost
    // to a phantom interrupt) still surfaces — the ring is the contract,
    // not the edge.
    if (inb(STATUS) & 1 != 0) {
        const sc = inb(DATA);
        const next = (head + 1) % ring.len;
        if (next != tail) {
            ring[head] = sc;
            head = next;
        }
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
