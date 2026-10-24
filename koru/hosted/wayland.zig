// koruos/hosted wayland surface provider — the `koruos.surface` +
// `koruos.input` ifaces over libwayland-client (wl_shm + xdg_shell).
//
// A surface is an xdg_toplevel backed by one wl_shm buffer we own:
// fill/px write our shm, present is attach-once + damage_buffer +
// commit — the protocol's commit/damage shape natively, not a pixel
// copy (XPutImage) like the X11 arm. The configure dance is honored:
// first commit → xdg_surface.configure → ack → attach. The configure
// is also the iface's `expose` (repaint demand): the compositor's
// first configure is "show us your frame", and every later one is a
// resize demand the koru side should repaint against.
//
// Input is the same registry connection: wl_seat → wl_keyboard +
// wl_pointer listeners drain into the shared raw InEv ring. Key codes
// are evdev codes — raw provider codes, same contract as the 8042 arm
// (and evdev 'a'==30 already coincides with set-1).
//
// Headers + generated protocol glue are vendored in koru/hosted/
// wayland/ (produced by wayland-scanner inside the vendored rootfs —
// the host has no wayland-dev). Links libwayland-client.so.0 by path.
//
// Single-buffer shm: the compositor samples live memory; tearing is
// possible and acceptable for this rung — a double-buffered pool is
// the honest upgrade when frame pacing lands.

const std = @import("std");
const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-client-protocol.h");
    @cInclude("xdg-shell-client-protocol.h");
});

const InEv = extern struct {
    kind: u32,    // 1=key, 2=button, 3=motion, 4=expose (repaint demand)
    code: u32,
    pressed: u32,
    dx: i32,
    dy: i32,
};

var inring: [64]InEv = undefined;
var inhead: usize = 0;
var intail: usize = 0;
fn inPush(ev: InEv) void {
    const next = (inhead + 1) % inring.len;
    if (next == intail) return; // full — drop, never overwrite
    inring[inhead] = ev;
    inhead = next;
}

// ---- global state ----------------------------------------------------
var dpy: ?*wl.wl_display = null;
var compositor: ?*wl.wl_compositor = null;
var shm: ?*wl.wl_shm = null;
var wm_base: ?*wl.xdg_wm_base = null;
var seat: ?*wl.wl_seat = null;
var seat_caps: u32 = 0;
var last_px: f64 = -1;
var last_py: f64 = -1;

const SEAT_CAP_POINTER: u32 = 1;
const SEAT_CAP_KEYBOARD: u32 = 2;

// ---- listeners -------------------------------------------------------
fn regGlobal(_: ?*anyopaque, reg: ?*wl.wl_registry, name: u32, iface: [*c]const u8, version: u32) callconv(.c) void {
    const eq = std.mem.eql;
    if (eq(u8, std.mem.span(iface), "wl_compositor")) {
        compositor = @ptrCast(wl.wl_registry_bind(reg, name, &wl.wl_compositor_interface, @min(version, 4)));
    } else if (eq(u8, std.mem.span(iface), "wl_shm")) {
        shm = @ptrCast(wl.wl_registry_bind(reg, name, &wl.wl_shm_interface, 1));
    } else if (eq(u8, std.mem.span(iface), "xdg_wm_base")) {
        wm_base = @ptrCast(wl.wl_registry_bind(reg, name, &wl.xdg_wm_base_interface, 1));
        _ = wl.xdg_wm_base_add_listener(wm_base, &wm_listener, null);
    } else if (eq(u8, std.mem.span(iface), "wl_seat")) {
        seat = @ptrCast(wl.wl_registry_bind(reg, name, &wl.wl_seat_interface, @min(version, 5)));
        _ = wl.wl_seat_add_listener(seat, &seat_listener, null);
    }
}
fn regRemove(_: ?*anyopaque, _: ?*wl.wl_registry, _: u32) callconv(.c) void {}
const registry_listener = wl.wl_registry_listener{ .global = regGlobal, .global_remove = regRemove };

fn wmPing(_: ?*anyopaque, base: ?*wl.xdg_wm_base, serial: u32) callconv(.c) void {
    wl.xdg_wm_base_pong(base, serial);
}
const wm_listener = wl.xdg_wm_base_listener{ .ping = wmPing };

fn seatCaps(_: ?*anyopaque, s: ?*wl.wl_seat, caps: u32) callconv(.c) void {
    seat_caps = caps;
    if (caps & SEAT_CAP_KEYBOARD != 0) {
        const kb = wl.wl_seat_get_keyboard(s);
        _ = wl.wl_keyboard_add_listener(kb, &kb_listener, null);
    }
    if (caps & SEAT_CAP_POINTER != 0) {
        const ptr = wl.wl_seat_get_pointer(s);
        _ = wl.wl_pointer_add_listener(ptr, &ptr_listener, null);
    }
}
fn seatName(_: ?*anyopaque, _: ?*wl.wl_seat, _: [*c]const u8) callconv(.c) void {}
const seat_listener = wl.wl_seat_listener{ .capabilities = seatCaps, .name = seatName };

// keyboard — evdev keycodes pass through raw
fn kbKeymap(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, fd: i32, _: u32) callconv(.c) void {
    // no xkbcommon on this arm — the iface carries raw codes; the fd's
    // keymap is consumed-and-closed, never mapped.
    _ = std.posix.system.close(fd);
}
fn kbEnter(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface, _: ?*wl.wl_array) callconv(.c) void {}
fn kbLeave(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: ?*wl.wl_surface) callconv(.c) void {}
fn kbKey(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
    inPush(.{ .kind = 1, .code = key, .pressed = state, .dx = 0, .dy = 0 });
}
fn kbMods(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}
fn kbRepeat(_: ?*anyopaque, _: ?*wl.wl_keyboard, _: i32, _: i32) callconv(.c) void {}
const kb_listener = wl.wl_keyboard_listener{
    .keymap = kbKeymap, .enter = kbEnter, .leave = kbLeave,
    .key = kbKey, .modifiers = kbMods, .repeat_info = kbRepeat,
};

// pointer — motion deltas, buttons raw
fn ptrEnter(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
    last_px = wl.wl_fixed_to_double(sx);
    last_py = wl.wl_fixed_to_double(sy);
}
fn ptrLeave(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: ?*wl.wl_surface) callconv(.c) void {
    last_px = -1; last_py = -1;
}
fn ptrMotion(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, sx: wl.wl_fixed_t, sy: wl.wl_fixed_t) callconv(.c) void {
    const x = wl.wl_fixed_to_double(sx);
    const y = wl.wl_fixed_to_double(sy);
    if (last_px >= 0) {
        const dx: i32 = @intFromFloat(x - last_px);
        const dy: i32 = @intFromFloat(y - last_py);
        if (dx != 0 or dy != 0) inPush(.{ .kind = 3, .code = 0, .pressed = 0, .dx = dx, .dy = dy });
    }
    last_px = x; last_py = y;
}
fn ptrButton(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32, button: u32, state: u32) callconv(.c) void {
    inPush(.{ .kind = 2, .code = button, .pressed = state, .dx = 0, .dy = 0 });
}
fn ptrAxis(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32, _: wl.wl_fixed_t) callconv(.c) void {}
fn ptrFrame(_: ?*anyopaque, _: ?*wl.wl_pointer) callconv(.c) void {}
fn ptrAxisSrc(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32) callconv(.c) void {}
fn ptrAxisStop(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: u32) callconv(.c) void {}
fn ptrAxisDisc(_: ?*anyopaque, _: ?*wl.wl_pointer, _: u32, _: i32) callconv(.c) void {}
const ptr_listener = wl.wl_pointer_listener{
    .enter = ptrEnter, .leave = ptrLeave, .motion = ptrMotion,
    .button = ptrButton, .axis = ptrAxis, .frame = ptrFrame,
    .axis_source = ptrAxisSrc, .axis_stop = ptrAxisStop,
    .axis_discrete = ptrAxisDisc,
};

// ---- display ---------------------------------------------------------
fn display() ?*wl.wl_display {
    if (dpy == null) {
        dpy = wl.wl_display_connect(null); // $WAYLAND_DISPLAY — WSLg wayland-0
        if (dpy == null) return null;
        const reg = wl.wl_display_get_registry(dpy) orelse return dpy;
        _ = wl.wl_registry_add_listener(reg, &registry_listener, null);
        _ = wl.wl_display_roundtrip(dpy); // globals
        _ = wl.wl_display_roundtrip(dpy); // seat caps + shm formats
    }
    return dpy;
}

pub export fn koruos_input_poll(out: *InEv) callconv(.c) u8 {
    const d = display() orelse return 0;
    _ = wl.wl_display_flush(d);
    // prepare_read/cancel_read is the sanctioned single-thread pattern:
    // read only when the fd is readable, always dispatch what's queued.
    while (wl.wl_display_prepare_read(d) == -1)
        _ = wl.wl_display_dispatch_pending(d);
    var fds = [_]std.posix.pollfd{.{
        .fd = wl.wl_display_get_fd(d),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const n = std.posix.poll(&fds, 0) catch 0;
    if (n > 0) {
        _ = wl.wl_display_read_events(d);
    } else {
        wl.wl_display_cancel_read(d);
    }
    _ = wl.wl_display_dispatch_pending(d);
    if (intail == inhead) return 0;
    out.* = inring[intail];
    intail = (intail + 1) % inring.len;
    return 1;
}

// ---- surfaces --------------------------------------------------------
const Surf = struct {
    surface: *wl.wl_surface,
    xsurf: *wl.xdg_surface,
    toplevel: *wl.xdg_toplevel,
    buf: *wl.wl_buffer,
    map: []align(std.heap.page_size_min) u8, // the shm region, for munmap
    pixels: []u32,
    w: u32,
    h: u32,
    configured: bool,
    attached: bool,
};

fn xsConfigure(sv: ?*anyopaque, xs: ?*wl.xdg_surface, serial: u32) callconv(.c) void {
    wl.xdg_surface_ack_configure(xs, serial);
    const s: *Surf = @ptrCast(@alignCast(sv));
    s.configured = true;
    // configure is the compositor's repaint demand — same semantic the
    // X11 arm's Expose event carries.
    inPush(.{ .kind = 4, .code = 0, .pressed = 0, .dx = 0, .dy = 0 });
}
const xs_listener = wl.xdg_surface_listener{ .configure = xsConfigure };

pub export fn koruos_surface_open(w: u32, h: u32, title: [*:0]const u8) callconv(.c) ?*anyopaque {
    const d = display() orelse return null;
    if (compositor == null or shm == null or wm_base == null) return null;

    const npix: usize = @as(usize, w) * h;
    const stride: usize = @as(usize, w) * 4;
    const size: usize = stride * h;
    const fd = std.posix.memfd_create("koru-wl-shm", 0) catch return null;
    std.posix.ftruncate(fd, @intCast(size)) catch {
        std.posix.close(fd);
        return null;
    };
    const mem = std.posix.mmap(null, size, std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED }, fd, 0) catch {
        std.posix.close(fd);
        return null;
    };
    const pool = wl.wl_shm_create_pool(shm, fd, @intCast(size)) orelse {
        std.posix.munmap(mem);
        std.posix.close(fd);
        return null;
    };
    const buf = wl.wl_shm_pool_create_buffer(pool, 0, @intCast(w), @intCast(h),
        @intCast(stride), wl.WL_SHM_FORMAT_XRGB8888) orelse {
        wl.wl_shm_pool_destroy(pool);
        std.posix.munmap(mem);
        std.posix.close(fd);
        return null;
    };
    wl.wl_shm_pool_destroy(pool); // pool may die; the buffer holds the mem
    std.posix.close(fd);

    const surf = wl.wl_compositor_create_surface(compositor) orelse {
        wl.wl_buffer_destroy(buf);
        std.posix.munmap(mem);
        return null;
    };
    const xs = wl.xdg_wm_base_get_xdg_surface(wm_base, surf) orelse {
        wl.wl_surface_destroy(surf);
        wl.wl_buffer_destroy(buf);
        std.posix.munmap(mem);
        return null;
    };
    const s = std.heap.c_allocator.create(Surf) catch {
        wl.xdg_surface_destroy(xs);
        wl.wl_surface_destroy(surf);
        wl.wl_buffer_destroy(buf);
        std.posix.munmap(mem);
        return null;
    };
    s.* = .{
        .surface = surf, .xsurf = xs,
        .toplevel = undefined, .buf = buf, .map = mem,
        .pixels = @as([*]u32, @ptrCast(@alignCast(mem)))[0..npix],
        .w = w, .h = h, .configured = false, .attached = false,
    };
    _ = wl.xdg_surface_add_listener(xs, &xs_listener, s);
    const tl = wl.xdg_surface_get_toplevel(xs) orelse {
        wl.xdg_surface_destroy(xs);
        wl.wl_surface_destroy(surf);
        wl.wl_buffer_destroy(buf);
        std.posix.munmap(mem);
        std.heap.c_allocator.destroy(s);
        return null;
    };
    s.toplevel = tl;
    wl.xdg_toplevel_set_title(tl, title);
    wl.wl_surface_commit(surf); // initial commit — configure arrives next
    var tries: usize = 0;
    while (!s.configured and tries < 1000) : (tries += 1)
        _ = wl.wl_display_roundtrip(d);
    return s;
}

pub export fn koruos_surface_fill(sv: *anyopaque, x: u32, y: u32, w: u32, h: u32, color: u32) callconv(.c) u8 {
    const s: *Surf = @ptrCast(@alignCast(sv));
    const x1 = @min(x + w, s.w);
    const y1 = @min(y + h, s.h);
    for (@min(y, s.h)..y1) |yy| {
        for (@min(x, s.w)..x1) |xx| {
            s.pixels[yy * s.w + xx] = color;
        }
    }
    return 1;
}

pub export fn koruos_surface_px(sv: *anyopaque, x: u32, y: u32, color: u32) callconv(.c) u8 {
    const s: *Surf = @ptrCast(@alignCast(sv));
    if (x >= s.w or y >= s.h) return 0;
    s.pixels[y * s.w + x] = color;
    return 1;
}

pub export fn koruos_surface_present(sv: *anyopaque, x: u32, y: u32, w: u32, h: u32) callconv(.c) u8 {
    const s: *Surf = @ptrCast(@alignCast(sv));
    const d = display() orelse return 0;
    const cx = @min(x, s.w);
    const cy = @min(y, s.h);
    const cw = @min(w, s.w - cx);
    const ch = @min(h, s.h - cy);
    if (cw == 0 or ch == 0) return 0; // empty damage — nothing to commit
    if (!s.attached) {
        wl.wl_surface_attach(s.surface, s.buf, 0, 0);
        s.attached = true;
    }
    wl.wl_surface_damage_buffer(s.surface, @intCast(cx), @intCast(cy), @intCast(cw), @intCast(ch));
    wl.wl_surface_commit(s.surface);
    _ = wl.wl_display_flush(d);
    return 1;
}

pub export fn koruos_surface_close(sv: *anyopaque) callconv(.c) u8 {
    const s: *Surf = @ptrCast(@alignCast(sv));
    wl.xdg_toplevel_destroy(s.toplevel);
    wl.xdg_surface_destroy(s.xsurf);
    wl.wl_surface_destroy(s.surface);
    wl.wl_buffer_destroy(s.buf);
    std.posix.munmap(s.map);
    std.heap.c_allocator.destroy(s);
    if (dpy) |d| _ = wl.wl_display_flush(d);
    return 1;
}
