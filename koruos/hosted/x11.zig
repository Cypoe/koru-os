// koruos/hosted X11 surface provider — the `koruos.surface` iface's
// host-libc mechanism.
//
// A surface is a mapped X window backed by one ZPixmap XImage whose pixel
// buffer we own: fill/px write our memory, present XPutImage+flushes. The
// connection is lazy on first open. The same connection is the input
// device: open() selects key/button/motion on the window and
// koruos_input_poll drains them into a raw ring — one connection, two
// honest seams. Window
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
extern fn XSelectInput(d: *Display, w: Window, mask: c_long) c_int;
extern fn XPending(d: *Display) c_int;
extern fn XNextEvent(d: *Display, ev: *XEvent) c_int;

// --- input: the koruos/input iface's host-libc mechanism --------------
// The same connection that owns surfaces is the input device: key/button/
// motion events arrive because open() selects them on the window. Raw
// codes only — X keycodes and button numbers pass through untranslated,
// matching what the 8042 hands koru-native. XEvent is the fixed 192-byte
// ABI union; we read the members we model, nothing else.
const InEv = extern struct {
    kind: u32,    // 1=key, 2=button, 3=motion, 4=expose (repaint demand)
    code: u32,
    pressed: u32,
    dx: i32,
    dy: i32,
};
const XKeyButtonEv = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: *Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    detail: c_uint, // keycode on key events, button number on button events
    same_screen: c_int,
};
const XEvent = extern union {
    type: c_int,
    kb: XKeyButtonEv,
    pad: [24]c_long,
};
const KeyPress: c_int = 2;
const KeyRelease: c_int = 3;
const ButtonPress: c_int = 4;
const ButtonRelease: c_int = 5;
const MotionNotify: c_int = 6;
const Expose: c_int = 12;
// KeyPress|KeyRelease|ButtonPress|ButtonRelease|PointerMotion|Exposure
const InputMask: c_long = 0x804F;

var inring: [64]InEv = undefined;
var inhead: usize = 0;
var intail: usize = 0;
var last_x: c_int = -1;
var last_y: c_int = -1;

fn inPush(ev: InEv) void {
    const next = (inhead + 1) % inring.len;
    if (next == intail) return; // full — drop, never overwrite
    inring[inhead] = ev;
    inhead = next;
}

fn xdrain() void {
    const d = display() orelse return;
    while (XPending(d) > 0) {
        var ev: XEvent = undefined;
        _ = XNextEvent(d, &ev);
        switch (ev.type) {
            KeyPress, KeyRelease => inPush(.{
                .kind = 1, .code = ev.kb.detail, .pressed = @intFromBool(ev.type == KeyPress), .dx = 0, .dy = 0,
            }),
            ButtonPress, ButtonRelease => inPush(.{
                .kind = 2, .code = ev.kb.detail, .pressed = @intFromBool(ev.type == ButtonPress), .dx = 0, .dy = 0,
            }),
            MotionNotify => {
                const dx: i32 = if (last_x < 0) 0 else @intCast(ev.kb.x - last_x);
                const dy: i32 = if (last_y < 0) 0 else @intCast(ev.kb.y - last_y);
                last_x = ev.kb.x;
                last_y = ev.kb.y;
                if (dx != 0 or dy != 0) inPush(.{ .kind = 3, .code = 0, .pressed = 0, .dx = dx, .dy = dy });
            },
            // The server repaints a fresh/exposed window with its
            // background — pixels presented before map are gone. Expose
            // IS the repaint demand (X/wayland agree): forward it as the
            // iface's invalidate event so the koru side repaints the
            // scene rather than trusting an early present.
            Expose => inPush(.{ .kind = 4, .code = 0, .pressed = 0, .dx = 0, .dy = 0 }),
            else => {},
        }
    }
}

pub export fn koruos_input_poll(out: *InEv) callconv(.c) u8 {
    xdrain();
    if (intail == inhead) return 0;
    out.* = inring[intail];
    intail = (intail + 1) % inring.len;
    return 1;
}

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
    _ = XSelectInput(d, win, InputMask);
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

pub export fn koruos_surface_present(sv: *anyopaque, x: u32, y: u32, w: u32, h: u32) callconv(.c) u8 {
    const s: *Surf = @ptrCast(@alignCast(sv));
    const d = display() orelse return 0;
    // damage rect: only this sub-rect is XPutImage'd — commit means damage.
    const cx = @min(x, s.w);
    const cy = @min(y, s.h);
    const cw = @min(w, s.w - cx);
    const ch = @min(h, s.h - cy);
    if (cw == 0 or ch == 0) return 0; // empty damage — nothing to commit
    _ = XPutImage(d, s.win, s.gc, s.img, @intCast(cx), @intCast(cy), @intCast(cx), @intCast(cy), cw, ch);
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
