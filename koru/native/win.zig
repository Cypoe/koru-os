// koru/native/win — the "kwin" window PRODUCER for the scene core.
//
// MC-1: N windows, not one. Each window is a producer-owned backing
// (dmabuf when the i915 device is up, pmm otherwise — kind named in the
// marker, never silent) painted once with chrome (border + titlebar +
// label + body), then registered with comp as a .window layer. The
// compositor owns geometry/z/focus/drag through the placement
// authority; this module owns only pixels + the titlebar focus repaint.
//
// What died vs the single-window version: the retained-restore snapshot
// (the scene's retained backings make it obsolete), the heal stride
// (console is a root layer now — no occlusion loss to heal), the
// generation rescan (present.zig owns surface re-targeting), and all
// drag/input logic (comp.tick hit-tests and drags).
//
// Focus chrome: titlebar colour is DERIVED from comp focus state each
// tick — repaint the strip into the backing + damageLayer, never store
// a second copy of "am I focused" anywhere but last_focus for change
// detection.

const std = @import("std");
const pmm = @import("pmm");
const mmio = @import("mmio");
const net = @import("net");
const text = @import("text.zig");
const comp = @import("comp");
const kms = @import("i915/kms.zig");

extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern var stdout: ?*anyopaque;

const WW: u32 = 320;
const WH: u32 = 200;
const TITLE_H: u32 = 22;
const BORDER: u32 = 2;
const MAX_WIN: usize = 8;

// XRGB8888 — same packing as the console/i915 paths.
const C_BODY: u32 = 0x002A2F3A;
const C_TITLE: u32 = 0x003040C0;
const C_TITLE_DIM: u32 = 0x00202E58;
const C_BORDER: u32 = 0x00D8DEE9;
const C_LABEL: u32 = 0x00F8F8F2;
const C_HINT: u32 = 0x008A93A6;

const NAMES = [_][]const u8{ "kwin0", "kwin1", "kwin2", "kwin3",
    "kwin4", "kwin5", "kwin6", "kwin7" };

const WinObj = struct {
    live: bool = false,
    handle: i32 = -1, // comp layer handle (stable slot)
    buf: [*]volatile u32 = undefined,
    pitch: u32 = 0, // pixels per row
    tok: ?u32 = null,
    pphys: u64 = 0,
    ppages: usize = 0,
    last_focus: bool = false,
};
var wins = [_]WinObj{.{}} ** MAX_WIN;
var spawned: u64 = 0;
var closed: u64 = 0;

fn sayU(comptime fmt: []const u8, args: anytype) void {
    var b: [224]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    b[s.len] = 0;
    _ = fputs(@ptrCast(&b), stdout);
    net.mirror(s);
}

// ---- pixel helpers (into a window backing) ---------------------------------

fn setPx(b: [*]volatile u32, p: u32, x: u32, y: u32, c: u32) void {
    b[@as(usize, @intCast(y)) * @as(usize, @intCast(p)) +
        @as(usize, @intCast(x))] = c;
}
fn fillRect(b: [*]volatile u32, p: u32, x0: u32, y0: u32, w: u32, h: u32, c: u32) void {
    var y = y0;
    while (y < y0 + h) : (y += 1) {
        var x = x0;
        while (x < x0 + w) : (x += 1) setPx(b, p, x, y, c);
    }
}
fn frameRect(b: [*]volatile u32, p: u32, w: u32, h: u32, t: u32, c: u32) void {
    fillRect(b, p, 0, 0, w, t, c);
    fillRect(b, p, 0, h - t, w, t, c);
    fillRect(b, p, 0, 0, t, h, c);
    fillRect(b, p, w - t, 0, t, h, c);
}
// 8x8 font into an arbitrary buffer — text.zig's glyph table, bit c of
// row r = column c, advance 9 like the console.
fn drawText(b: [*]volatile u32, p: u32, x0: u32, y0: u32, s: []const u8, c: u32) void {
    var x = x0;
    for (s) |ch| {
        if (ch >= 0x20 and ch < 0x80) {
            const g = text.font[ch & 0x7F];
            var r: usize = 0;
            while (r < 8) : (r += 1) {
                var col: usize = 0;
                while (col < 8) : (col += 1) {
                    if (((g[r] >> @intCast(col)) & 1) != 0)
                        setPx(b, p, x + @as(u32, @intCast(col)),
                            y0 + @as(u32, @intCast(r)), c);
                }
            }
        }
        x += 9;
    }
}

// ---- the window's own pixels ---------------------------------------------------

fn paintTitle(w: *WinObj, idx: usize, focused: bool) void {
    const tc = if (focused) C_TITLE else C_TITLE_DIM;
    fillRect(w.buf, w.pitch, BORDER, BORDER, WW - 2 * BORDER, TITLE_H - 2 * BORDER, tc);
    drawText(w.buf, w.pitch, 10, BORDER + (TITLE_H - 2 * BORDER - 8) / 2,
        NAMES[idx], C_LABEL);
}

fn paintWindow(w: *WinObj, idx: usize) void {
    const body = C_BODY + @as(u32, @intCast(idx)) * 0x00010101; // per-window tint
    fillRect(w.buf, w.pitch, 0, 0, WW, WH, body);
    frameRect(w.buf, w.pitch, WW, WH, BORDER, C_BORDER);
    paintTitle(w, idx, true);
    drawText(w.buf, w.pitch, 10, TITLE_H + 8, "drag me", C_HINT);
}

// ---- backing free ---------------------------------------------------------------

fn freeWin(w: *WinObj) void {
    if (w.tok) |t| {
        kms.dmabufUnref(t);
        w.tok = null;
    } else if (w.pphys != 0) {
        _ = pmm.freeBlock(w.pphys, w.ppages);
        w.pphys = 0;
    }
    w.buf = undefined;
    w.pitch = 0;
}

// ---- spawn / close ---------------------------------------------------------------

pub fn spawn() void {
    var slot: ?usize = null;
    for (wins[0..], 0..) |*w, i| {
        if (!w.live) {
            slot = i;
            break;
        }
    }
    const si = slot orelse {
        sayU("KORU kwin: pool full ({d})\n", .{MAX_WIN});
        text.puts("kwin: pool full\n");
        return;
    };
    var w = WinObj{};
    // try dmabuf first — need the token kept, so alloc inline
    var kind: []const u8 = "pmm";
    if (kms.device().up) {
        if (kms.dmabufCreate(WW, WH)) |t| {
            if (kms.dmabufMap(t)) |b| {
                if (b.map) |m| {
                    w.tok = t;
                    w.buf = m;
                    w.pitch = b.pitch / 4;
                    kind = "dmabuf";
                }
            }
            if (w.tok == null) kms.dmabufUnref(t);
        }
    }
    if (w.pitch == 0) {
        const bytes = @as(u64, WW) * WH * 4;
        const pages: usize = @intCast((bytes + 4095) / 4096);
        const phys = pmm.allocContiguous(pages, 1) orelse {
            sayU("KORU kwin: backing alloc failed\n", .{});
            text.puts("kwin: alloc failed\n");
            return;
        };
        if (!mmio.map(phys, bytes)) {
            _ = pmm.freeBlock(phys, pages);
            sayU("KORU kwin: backing map failed\n", .{});
            text.puts("kwin: map failed\n");
            return;
        }
        w.pphys = phys;
        w.ppages = pages;
        w.buf = @ptrFromInt(@as(usize, @intCast(phys)));
        w.pitch = WW;
        kind = "pmm";
    }
    paintWindow(&w, si);

    // cascade placement — desired pos; comp's decide() clamps.
    var sw: u32 = 0;
    var sh: u32 = 0;
    comp.dims(&sw, &sh);
    const off: i64 = @as(i64, @intCast(si)) * 28;
    const maxX: i64 = @as(i64, @intCast(sw)) - WW;
    const maxY: i64 = @as(i64, @intCast(sh)) - WH;
    const cx: i64 = @divTrunc(@as(i64, sw), 2) - WW / 2 + off;
    const cy: i64 = @divTrunc(@as(i64, sh), 2) - WH / 2 + 24 + off;
    const dx: u32 = @intCast(@max(@as(i64, 0), @min(cx, @max(@as(i64, 0), maxX))));
    const dy: u32 = @intCast(@max(@as(i64, 0), @min(cy, @max(@as(i64, 0), maxY))));

    const buf: [*]u32 = @volatileCast(w.buf);
    const handle = comp.windowOpen(buf, w.pitch, WW, WH, dx, dy, TITLE_H, si);
    if (handle < 0) {
        freeWin(&w);
        sayU("KORU kwin: scene refused window\n", .{});
        text.puts("kwin: scene refused\n");
        return;
    }
    w.handle = handle;
    w.live = true;
    w.last_focus = comp.isFocused(handle); // windowOpen focuses+raises
    wins[si] = w;
    spawned += 1;
    sayU("KORU kwin spawn {d} 320x200 handle={d} backing={s}\n",
        .{ si, handle, kind });
    text.puts("kwin: window up — press+drag titlebar to move\n");
    if (!cursorMod.isEnabled()) cursorMod.enable();
}

// close the focused window, else the topmost — 'kwclose'.
pub fn closeTop() void {
    var h = comp.focusedWindow();
    if (h < 0) h = comp.topWindow();
    if (h < 0) {
        sayU("KORU kwin: nothing to close\n", .{});
        text.puts("kwin: no windows\n");
        return;
    }
    var found: ?usize = null;
    for (wins[0..], 0..) |*w, i| {
        if (w.live and w.handle == h) {
            found = i;
            break;
        }
    }
    const si = found orelse {
        // a scene window we don't own (surf/shell-spawned) — detach only
        comp.detach(h);
        sayU("KORU kwin close foreign handle={d}\n", .{h});
        return;
    };
    var w = wins[si];
    comp.detach(h); // vacated rect damages -> reveal beneath
    freeWin(&w);
    w.live = false;
    w.handle = -1;
    wins[si] = w;
    closed += 1;
    sayU("KORU kwin close {d} handle={d}\n", .{ si, h });
    text.puts("kwin: window closed\n");
}

// ---- per-tick producer update -----------------------------------------------------
// Focus chrome only: repaint the titlebar strip when comp's focus state
// flips, then damage that backing rect into the scene.

pub fn tick() void {
    for (wins[0..], 0..) |*w, i| {
        if (!w.live) continue;
        const f = comp.isFocused(w.handle);
        if (f != w.last_focus) {
            w.last_focus = f;
            paintTitle(w, i, f);
            _ = comp.damageLayer(w.handle, BORDER, BORDER,
                WW - 2 * BORDER, TITLE_H - 2 * BORDER);
        }
    }
}

// cursor wiring — the scene owns input; we only ensure the pointer
// exists so titlebar drags have a cursor to grab.
const cursorMod = @import("cursor.zig");
