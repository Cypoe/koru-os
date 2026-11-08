// koru/native/dserial — minimal serial sink for the efault diagnostic boot.
//
// Provides the koru_say/koru_putdec externs that net/e1000e/pci/faults/
// efault/pmm-adjacent code links against, WITHOUT pulling user.zig's
// monolithic task/surface runtime (which is how the normal boot provides
// them). Same mechanism user.zig's say() uses underneath: fputs on the
// runtime stdout (COM1 UART). The VGA text mirror is omitted — the GRUB
// fb oracle is the panel, not 0xB8000.
//
// Diagnostic-only: when normal boot returns, user.zig owns these symbols
// again and this module is dropped from the import graph.

extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern var stdout: ?*anyopaque;

pub export fn koru_say(s: [*:0]const u8) callconv(.c) void {
    _ = fputs(s, stdout);
}

pub export fn koru_putdec(v: u64) callconv(.c) void {
    var buf: [21]u8 = undefined;
    buf[20] = 0;
    var i: usize = 20;
    var n = v;
    if (n == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (n != 0) {
        i -= 1;
        buf[i] = @intCast('0' + n % 10);
        n /= 10;
    }
    _ = fputs(@ptrCast(&buf[i]), stdout);
}
