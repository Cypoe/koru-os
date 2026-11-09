// koru/native/win — the "kwin" window PRODUCER for the scene core.
//
// MC-1: N windows, not one. Each window is a producer-owned backing
// (backing = pre-allocated pool slice — CPU-composited, never scanned).
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
const cmdview = @import("cmdview.zig");
// (i915/kms not imported — window backings are CPU-side pool slices)

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
    pool_i: i32 = -1, // backing-pool slice index, -1 = none
    last_focus: bool = false,
    title: []const u8 = "",
    // MC-3 ui windows: body pixels come from the CmdView rasterizer,
    // not paintWindow's test pattern. hot = pointer-inside-button
    // state (stream B); ctr_* = live counter slot (ud==90) clocked by
    // TSC so it advances in real time, not loop iterations.
    ui: bool = false,
    hot: bool = false,
    ctr_sec: u32 = 0,
    ctr_tsc: u64 = 0,
};
var wins = [_]WinObj{.{}} ** MAX_WIN;
var spawned: u64 = 0;
var closed: u64 = 0;

// Window backing pool — allocated ONCE at shell init, before 'kms'
// dumbs fragment RAM. Window backings are CPU-composited only (the
// display engine never scans them), so they need VA-contiguous
// memory — NOT physically-contiguous pages and NOT GTT/dmabuf
// mapping. One contiguous run sliced into MAX_WIN backings; spawn is
// an O(1) handout. The per-spawn allocContiguous(63) scan cost 3.7
// SECONDS on T590 post-modeset (fragmented freelist) — frozen shell,
// corrupted drag state. Pool handout can't stall: ~ns.
const POOL_BYTES: usize = @as(usize, WW) * WH * 4;
var pool_buf: [*]volatile u32 = undefined;
var pool_ready: bool = false;
var pool_free = [_]bool{true} ** MAX_WIN;

pub fn poolInit() void {
    const pages: usize = @intCast((POOL_BYTES * MAX_WIN + 4095) / 4096);
    const phys = pmm.allocContiguous(pages, 1) orelse {
        sayU("KORU kwin: backing pool alloc failed\n", .{});
        return;
    };
    if (!mmio.map(phys, @as(u64, POOL_BYTES) * MAX_WIN)) {
        _ = pmm.freeBlock(phys, pages);
        sayU("KORU kwin: backing pool map failed\n", .{});
        return;
    }
    pool_buf = @ptrFromInt(@as(usize, @intCast(phys)));
    pool_ready = true;
    sayU("KORU kwin: backing pool up {d}x{d}B x{d}\n", .{ WW, WH, MAX_WIN });
}

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
    _ = idx;
    const tc = if (focused) C_TITLE else C_TITLE_DIM;
    fillRect(w.buf, w.pitch, BORDER, BORDER, WW - 2 * BORDER, TITLE_H - 2 * BORDER, tc);
    drawText(w.buf, w.pitch, 10, BORDER + (TITLE_H - 2 * BORDER - 8) / 2,
        w.title, C_LABEL);
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
    if (w.pool_i >= 0) {
        pool_free[@intCast(w.pool_i)] = true;
        w.pool_i = -1;
    }
    w.buf = undefined;
    w.pitch = 0;
}

// ---- spawn / close ---------------------------------------------------------------

fn tsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo), [hi] "={edx}" (hi),
        :
        : .{ .memory = true });
    return (@as(u64, hi) << 32) | lo;
}

// MC-3: a ui window's body is the CmdView rasterizer's output — the
// real oshun component (button + label + live counter) solved
// off-target and shipped as ui_cmds.txt. Chrome (frame+titlebar) stays
// compositor-side; the body region is cmdview's 316x174 canvas at
// backing offset (2,24).
fn paintUi(w: *WinObj) void {
    fillRect(w.buf, w.pitch, 0, 0, WW, WH, C_BODY);
    frameRect(w.buf, w.pitch, WW, WH, BORDER, C_BORDER);
    paintTitle(w, 0, true);
    cmdview.ensure();
    cmdview.setCounter(0);
    cmdview.render(w.buf, w.pitch, 0); // stream A — normal palette
}

// repaint the component body from the active stream + damage it.
fn repaintUi(w: *WinObj) void {
    cmdview.render(w.buf, w.pitch, if (w.hot) 1 else 0);
    _ = comp.damageLayer(w.handle, cmdview.OX, cmdview.OY, cmdview.CW, cmdview.CH);
}

// per-tick ui producer update: hover hit-test (pointer -> canvas coords
// via comp's scene origin) flips the hot stream; the TSC-clocked counter
// advances the live text slot ~1/2s. Both repaint through the same
// damage path as everything else.
fn uiTick(w: *WinObj) void {
    var px: i32 = 0;
    var py: i32 = 0;
    var on: bool = false;
    var btn: u32 = 0;
    comp.pointerPos(&px, &py, &on, &btn);
    var sx: u32 = 0;
    var sy: u32 = 0;
    if (comp.scenePos(w.handle, &sx, &sy)) {
        const lx = px - @as(i32, @intCast(sx)) - cmdview.OX;
        const ly = py - @as(i32, @intCast(sy)) - cmdview.OY;
        const hot = on and cmdview.hitButton(lx, ly);
        if (hot != w.hot) {
            w.hot = hot;
            repaintUi(w);
            sayU("KORU kwin ui hot={d}\n", .{@intFromBool(hot)});
        }
    }
    const now = tsc();
    if (w.ctr_tsc == 0) w.ctr_tsc = now;
    // ~2s per count at ~2.5GHz TSC — real time, not loop iterations
    if (now - w.ctr_tsc > 5_000_000_000) {
        w.ctr_tsc = now;
        w.ctr_sec +%= 1;
        if (w.ctr_sec > 9999) w.ctr_sec = 0;
        cmdview.setCounter(w.ctr_sec);
        repaintUi(w);
    }
}

pub fn spawn() void {
    spawnImpl(false);
}

// 'kwui' — the oshun/CmdView window.
pub fn spawnUi() void {
    spawnImpl(true);
}

fn spawnImpl(ui: bool) void {
    const t0 = tsc(); // phase timing -> spawn marker (T590 slow-open profile)
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
    if (!pool_ready) {
        sayU("KORU kwin: backing pool down — spawn refused\n", .{});
        text.puts("kwin: backing pool down\n");
        return;
    }
    var pi: ?usize = null;
    for (pool_free[0..], 0..) |f, i| {
        if (f) {
            pi = i;
            break;
        }
    }
    const pidx = pi orelse {
        sayU("KORU kwin: backing pool exhausted\n", .{});
        text.puts("kwin: pool exhausted\n");
        return;
    };
    pool_free[pidx] = false;
    w.pool_i = @intCast(pidx);
    w.buf = pool_buf + pidx * (POOL_BYTES / 4);
    w.pitch = WW;
    const t1 = tsc(); // alloc done (pool handout — ~ns)
    if (ui) {
        w.ui = true;
        w.title = "oshun";
        paintUi(&w);
    } else {
        w.title = NAMES[si];
        paintWindow(&w, si);
    }
    const t2 = tsc(); // paint done

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
    const t3 = tsc(); // attach/scene done
    sayU("KORU kwin spawn {d} 320x200 handle={d} backing={s} us alloc={d} paint={d} attach={d}\n",
        .{ si, handle, "pool",
           (t1 - t0) / 3000, (t2 - t1) / 3000, (t3 - t2) / 3000 });
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
        if (w.ui) uiTick(w);
    }
}

// cursor wiring — the scene owns input; we only ensure the pointer
// exists so titlebar drags have a cursor to grab.
const cursorMod = @import("cursor.zig");
