// koruos/native surface provider — koruos/surface over the fb seam.
//
// A surface is what the hosted arms already agreed it is: a provider-
// owned pixel buffer + a commit point + a pair-release lifetime. On this
// arm the provider is also the placement authority — there is no window
// manager, so open() cascades each slot onto the screen like one. That
// is a named bound, not an accident: real stacking/compositing is the
// nativeCompositor rung; painter's-order-at-present is the only z-rule
// here, and an un-presented pixel exists only in the backing.
//
// fill/px write the backing — never the display. present(damage) blits
// the clipped rect onto the display backend, then commits it through
// fb's own present (TRANSFER+FLUSH on virtio-gpu, trivial on an LFB).
// A zero-area present refuses — commit means damage. A pointer that
// isn't a live pool slot refuses — the token is a handle, not an
// address to trust.

const fb = @import("fb.zig");
const pmm = @import("pmm");

extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;

const MAX_SURF = 8;

const Surf = struct {
    live: bool = false,
    x: u32 = 0, // screen placement — the provider's, like a WM's
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    buf: [*]u32 = undefined,
    phys: u64 = 0,
    pages: usize = 0,
};

var pool = [_]Surf{.{}} ** MAX_SURF;
var opened: u64 = 0;
var closed: u64 = 0;

fn asSurf(p: ?*anyopaque) ?*Surf {
    const s: *Surf = @ptrCast(@alignCast(p orelse return null));
    for (&pool) |*slot| {
        if (slot == s) return if (slot.live) slot else null;
    }
    return null;
}

pub export fn koruos_surface_open(w: u32, h: u32, title: [*:0]const u8) callconv(.c) ?*anyopaque {
    _ = title; // no WM to label — the arg stays on the wire, honored later
    if (w == 0 or h == 0) return null;
    var info: fb.Info = undefined;
    if (fb.koruos_fb_info(&info) == 0) return null; // no display backend
    if (w > info.width or h > info.height) return null;
    const bytes = @as(u64, w) * h * 4;
    const pages: usize = @intCast((bytes + 4095) / 4096);
    const phys = pmm.allocContiguous(pages, 1) orelse return null;
    for (&pool, 0..) |*s, i| {
        if (s.live) continue;
        const n: u32 = @intCast(i);
        s.* = .{
            .live = true,
            .x = @min(24 + n * 56, info.width -| w),
            .y = @min(24 + n * 40, info.height -| h),
            .w = w,
            .h = h,
            .buf = @ptrFromInt(@as(usize, @intCast(phys))),
            .phys = phys,
            .pages = pages,
        };
        @memset(s.buf[0 .. w * h], 0);
        opened += 1;
        koru_say("surf: open ");
        koru_putdec(w);
        koru_say("x");
        koru_putdec(h);
        koru_say(" at ");
        koru_putdec(s.x);
        koru_say(",");
        koru_putdec(s.y);
        koru_say("\n");
        return s;
    }
    _ = pmm.freeBlock(phys, pages); // pool full — refuse, keep the frames
    return null;
}

pub export fn koruos_surface_fill(p: ?*anyopaque, x: u32, y: u32, w: u32, h: u32, color: u32) callconv(.c) u8 {
    const s = asSurf(p) orelse return 0;
    const x1 = @min(x + w, s.w);
    const y1 = @min(y + h, s.h);
    var yy = @min(y, s.h);
    while (yy < y1) : (yy += 1) {
        var xx = @min(x, s.w);
        while (xx < x1) : (xx += 1) s.buf[yy * s.w + xx] = color;
    }
    return 1;
}

pub export fn koruos_surface_px(p: ?*anyopaque, x: u32, y: u32, color: u32) callconv(.c) u8 {
    const s = asSurf(p) orelse return 0;
    if (x >= s.w or y >= s.h) return 0;
    s.buf[y * s.w + x] = color;
    return 1;
}

pub export fn koruos_surface_present(p: ?*anyopaque, x: u32, y: u32, w: u32, h: u32) callconv(.c) u8 {
    const s = asSurf(p) orelse return 0;
    if (w == 0 or h == 0) return 0; // commit means damage
    const x1 = @min(x + w, s.w);
    const y1 = @min(y + h, s.h);
    var yy = @min(y, s.h);
    if (yy >= y1) return 0;
    while (yy < y1) : (yy += 1) {
        var xx = @min(x, s.w);
        while (xx < x1) : (xx += 1)
            _ = fb.koruos_fb_px(s.x + xx, s.y + yy, s.buf[yy * s.w + xx]);
    }
    return fb.koruos_fb_present(s.x + x, s.y + y, x1 - x, y1 - y);
}

pub export fn koruos_surface_close(p: ?*anyopaque) callconv(.c) u8 {
    const s = asSurf(p) orelse return 0;
    _ = pmm.freeBlock(s.phys, s.pages);
    s.live = false;
    closed += 1;
    return 1;
}
