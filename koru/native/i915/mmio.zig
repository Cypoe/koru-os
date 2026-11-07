// koru/native i915/mmio — register + GTT access layer, ported from
// libgfxinit common/hw-gfx-gma-registers.adb (coreboot, GPL-2.0).
//
// Registers are dword MMIO at BAR0+offset (identity-mapped by mmio.map).
// GTT PTEs are qword at BAR0+0x800000 (MMIO_GTT_64_Offset), 4KiB pages,
// 39-bit phys: PTE = (addr & 0x7ffffffff000) | valid.
//
// Timeouts use ukplat_monotonic_clock (ns) from runtime.zig.

const regs = @import("regs.zig");
pub const R = regs.R;

extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;
const hostmmio = @import("mmio"); // module root — path import would double-claim
extern fn ukplat_monotonic_clock() callconv(.c) u64;

pub var bar: [*]volatile u32 = undefined; // MMIO BAR0 base (identity VA)
pub var gtt64: [*]volatile u64 = undefined; // BAR0 + 0x800000

const GTT_PAGE: u64 = 4096;
const GTT_ADDR_MASK: u64 = 0x7fff_ffff_f000;
pub const GTT_PTE_VALID: u64 = 1;

pub fn setBase(base: u64, gttBase: u64) void {
    // BAR0 must be identity-mapped into the kernel page tables first —
    // the host maps phys on demand (fb.zig does the same). Unmapped
    // MMIO = #PF = (pre-IDT) triple fault = silent reset.
    if (!hostmmio.map(base, 0x100_0000)) {
        koru_say("i915: BAR0 map failed\n");
    }
    bar = @ptrFromInt(@as(usize, @intCast(base)));
    gtt64 = @ptrFromInt(@as(usize, @intCast(gttBase)));
}

pub fn rd(off: u32) u32 {
    return bar[off >> 2];
}
pub fn wr(off: u32, v: u32) void {
    bar[off >> 2] = v;
}
pub fn postingRead(off: u32) void {
    _ = rd(off);
}

pub fn nowMs() u64 {
    return ukplat_monotonic_clock() / 1_000_000;
}
pub fn sleepMs(ms: u64) void {
    const deadline = nowMs() + ms;
    while (nowMs() < deadline) asm volatile ("pause");
}
pub fn sleepUs(us: u64) void {
    const deadline = ukplat_monotonic_clock() + us * 1000;
    while (ukplat_monotonic_clock() < deadline) asm volatile ("pause");
}

pub const DefaultTimeoutMs: u32 = 10;

// Wait until (rd & mask) == value. false on timeout.
pub fn wait(off: u32, mask: u32, value: u32, timeoutMs: u32) bool {
    const deadline = nowMs() + timeoutMs;
    while (true) {
        if ((rd(off) & mask) == value) return true;
        if (nowMs() >= deadline) return false;
    }
}
pub fn waitSet(off: u32, mask: u32, timeoutMs: u32) bool {
    return wait(off, mask, mask, timeoutMs);
}
pub fn waitUnset(off: u32, mask: u32, timeoutMs: u32) bool {
    return wait(off, mask, 0, timeoutMs);
}

pub fn isSet(off: u32, mask: u32) bool {
    return (rd(off) & mask) == mask;
}
pub fn setMask(off: u32, mask: u32) void {
    wr(off, rd(off) | mask);
}
pub fn unsetMask(off: u32, mask: u32) void {
    wr(off, rd(off) & ~mask);
}
pub fn unsetAndSet(off: u32, unset: u32, set: u32) void {
    wr(off, (rd(off) & ~unset) | set);
}

// ---- GTT -----------------------------------------------------------------

// Write_GTT: GTT_Page is the 4KiB page index into the aperture;
// Device_Address is the target physical address.
pub fn writeGtt(page: u32, phys: u64, valid: bool) void {
    gtt64[page] = (phys & GTT_ADDR_MASK) | (if (valid) GTT_PTE_VALID else 0);
}
pub fn readGtt(page: u32) struct { phys: u64, valid: bool } {
    const pte = gtt64[page];
    return .{ .phys = pte & GTT_ADDR_MASK, .valid = (pte & GTT_PTE_VALID) != 0 };
}

// Fences are only needed for X/Y-tiled scanout; M0 uses Linear, so
// Add_Fence/Remove_Fence are intentionally not ported yet.

fn hexw(v: u64, comptime w: usize, buf: *[16]u8) void {
    var i: usize = 0;
    while (i < w) : (i += 1) {
        const nib = (v >> @intCast(4 * (w - 1 - i))) & 0xF;
        buf[i] = "0123456789abcdef"[@intCast(nib)];
    }
}

// DIAG: dump a register window — the bring-up oracle when the screen
// is the only feedback. Prints "name=hhhhhhhh" per line on serial.
pub fn dumpReg(name: [*:0]const u8, off: u32) void {
    var buf: [16]u8 = undefined;
    hexw(rd(off), 8, &buf);
    buf[8] = 0;
    koru_say(name);
    koru_say("=");
    koru_say(@ptrCast(&buf));
    koru_say("\n");
}

pub fn sayDec(v: u64) void {
    var buf: [20]u8 = undefined;
    var i: usize = 20;
    var n = v;
    if (n == 0) {
        i -= 1; buf[i] = '0';
    } else {
        while (n != 0) : (n /= 10) {
            i -= 1; buf[i] = '0' + @as(u8, @intCast(n % 10));
        }
    }
    const len = 20 - i;
    var z: [21]u8 = undefined;
    var j: usize = 0;
    while (j < len) : (j += 1) z[j] = buf[i + j];
    z[len] = 0;
    say(@ptrCast(&z));
}
pub var textHook: ?*const fn([*:0]const u8) void = null;

pub fn say(s: [*:0]const u8) void {
    koru_say(s);
    if (textHook) |h| h(s);
}
pub fn yn(b: bool) [*:0]const u8 {
    return if (b) @as([*:0]const u8, "yes") else @as([*:0]const u8, "no");
}
pub fn ynl(b: bool) [*:0]const u8 {
    return if (b) @as([*:0]const u8, "yes\n") else @as([*:0]const u8, "no\n");
}
pub fn sayHex(v: u64) void {
    var buf: [16]u8 = undefined;
    hexw(v, 8, &buf);
    buf[8] = 0;
    say("0x");
    say(@ptrCast(&buf));
}
