// koruos/hosted X11 surface provider — the `koruos.surface` iface's
// host-libc mechanism.
//
// A surface is a mapped X window backed by one ZPixmap XImage whose pixel
// buffer we own: fill/px write our memory, present XPutImage+flushes. The
// connection is lazy on first open; there is no event loop — input is a
// different provider family, and nothing here pretends otherwise. Window
// destruction is honest on close (XDestroyWindow), and XCloseDisplay at
// process exit finishes what the wire started.
//
// FFI reality: Xlib macros like DefaultRootWindow read Display internals;
// their X-prefixed function twins (XDefaultRootWindow, XDefaultGC, …) are
// real exports, which is all this file uses. Linked as
// libX11.so.6 by path — no dev package required.

const Display = opaque {};
const Visual = opaque {};
const GC = opaque {};
const XImage = opaque {};
const Window = c_ulong;

extern fn XOpenDisplay(name: ?[*:0]const u8) ?*Display;
extern fn XDefaultScreen(d: *Display) c_int;
extern fn XDefaultRootWindow(d: *Display) Window;
extern fn XDefaultVisual(d: *Display, scr: c_int) *Visual;
extern fn XDefaultDepth(d: *Display, scr: c_int) c_int;
extern fn XDefaultGC(d: *Display, scr: c_int) *GC;
extern fn XBlackPixel(d: *Display, scr: c_int) c_ulong;
extern fn XCreateSimpleWindow(d: *Display, parent: Window, x: c_int, y: c_int, w: c_uint, h: c_uint, bw: c_uint, border: c_ulong, bg: c_ulong) Window;
extern fn XStoreName(d: *Display, w: Window, name: [*:0]const u8) c_int;
extern fn XMapWindow(d: *Display, w: Window) c_int;
extern fn XDestroyWindow(d: *Display, w: Window) c_int;
extern fn XCreateImage(d: *Display, v: *Visual, depth: c_uint, format: c_int, offset: c_int, data: [*]u8, w: c_uint, h: c_uint, bitmap_pad: c_int, bytes_per_line: c_int) ?*XImage;
extern fn XDestroyImage(img: *XImage) c_int;
extern fn XPutImage(d: *Display, w: Window, gc: *GC, img: *XImage, src_x: c_int, src_y: c_int, dst_x: c_int, dst_y: c_int, w: c_uint, h: c_uint) c_int;
extern fn XFlush(d: *Display) c_int;
extern fn XSync(d: *Display, discard: c_int) c_int;

const Surf = struct {
    win: Window,
    img: *XImage,
    buf: []u32,
    w: u32,
    h: u32,
    gc: *GC,
};

var dpy: ?*Display = null;
var scr: c_int = 0;

const ZPixmap: c_int = 2;

fn display() ?*Display {
    if (dpy == null) {
        dpy = XOpenDisplay(null); // $DISPLAY — WSLg :0
        if (dpy) |d| scr = XDefaultScreen(d);
    }
    return dpy;
}

pub export fn koruos_surface_open(w: u32, h: u32, title: [*:0]const u8) callconv(.c) ?*anyopaque {
    const d = display() orelse return null;
    const buf = @import("std").heap.c_allocator.alloc(u32, @as(usize, w) * h) catch return null;
    const img = XCreateImage(d, XDefaultVisual(d, scr), @intCast(XDefaultDepth(d, scr)), ZPixmap,
        0, @ptrCast(buf.ptr), w, h, 32, @intCast(w * 4)) orelse {
        @import("std").heap.c_allocator.free(buf);
        return null;
    };
    const win = XCreateSimpleWindow(d, XDefaultRootWindow(d), 32, 32, w, h, 0,
        XBlackPixel(d, scr), XBlackPixel(d, scr));
    _ = XStoreName(d, win, title);
    _ = XMapWindow(d, win);
    const s = @import("std").heap.c_allocator.create(Surf) catch {
        _ = XDestroyImage(img);
        @import("std").heap.c_allocator.free(buf);
        return null;
    };
    s.* = .{ .win = win, .img = img, .buf = buf, .w = w, .h = h, .gc = XDefaultGC(d, scr) };
    _ = XFlush(d);
    return s;
}

pub export fn koruos_surface_fill(sv: *anyopaque, x: u32, y: u32, w: u32, h: u32, color: u32) callconv(.c) u8 {
    const s: *Surf = @ptrCast(@alignCast(sv));
    const x1 = @min(x + w, s.w);
    const y1 = @min(y + h, s.h);
    var yy = @min(y, s.h);
    while (yy < y1) : (yy += 1) {
        var xx = @min(x, s.w);
        while (xx < x1) : (xx += 1) s.buf[yy * s.w + xx] = color;
    }
    return 1;
}

pub export fn koruos_surface_px(sv: *anyopaque, x: u32, y: u32, color: u32) callconv(.c) u8 {
    const s: *Surf = @ptrCast(@alignCast(sv));
    if (x >= s.w or y >= s.h) return 0;
    s.buf[y * s.w + x] = color;
    return 1;
}

pub export fn koruos_surface_present(sv: *anyopaque) callconv(.c) u8 {
    const s: *Surf = @ptrCast(@alignCast(sv));
    const d = display() orelse return 0;
    _ = XPutImage(d, s.win, s.gc, s.img, 0, 0, 0, 0, s.w, s.h);
    _ = XFlush(d);
    return 1;
}

pub export fn koruos_surface_close(sv: *anyopaque) callconv(.c) u8 {
    const s: *Surf = @ptrCast(@alignCast(sv));
    const d = display() orelse return 0;
    _ = XDestroyWindow(d, s.win);
    _ = XDestroyImage(s.img); // frees img and its ->data (our buf)
    _ = XFlush(d);
    @import("std").heap.c_allocator.destroy(s);
    return 1;
}
