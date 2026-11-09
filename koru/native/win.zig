// koru/native/win — the first movable compositor surface ("kwin").
//
// One opaque window, software-composited onto the console scanout:
// a 320x200 backing buffer painted once (border + titlebar + font
// label + solid body), then blitted over the scanout at (wx,wy).
// The scanout target is whatever fb.scanout() reports — the GRUB/EFI
// LFB before 'kms', the i915 dumb buffer after rebase — so the window
// rides the proven console surface either way.
//
// Backing: a dmabuf export when the i915 KMS device is up (the M3
// producer->scanout seam, CPU side only — the window is composited,
// never scanned directly), contiguous pmm frames otherwise. The kind
// is named in the create marker; never silently chosen.
//
// Damage model is retained-restore, not damage lists: before the
// window covers a rect we snapshot the scanout pixels beneath it;
// moving restores the vacated rect, re-snapshots the destination,
// and blits. Console output printed under the window while it was up
// is occluded — standard retained-mode loss, named not hidden. A slow
// heal stride re-blits the window so glyph bleed self-repairs.
//
// Input: cursor.zig owns pointer position + held buttons; this module
// hit-tests the sprite tip against the window rect. Press-inside +
// motion = drag, release = drop. The XOR cursor sprite must never be
// painted over by a non-XOR blit, so every composite runs between
// cursor.compositeSuspend() (sprite erased, scene pixels restored)
// and cursor.compositeResume() (sprite redrawn on top) — the ordering
// a real scanout compositor uses.
//
// Generation discipline: every scanout access is gated on
// fb.generation() matching the gen captured at create/rescan. A kms
// flip/modeset repoints fb_base — restoring or snapshotting the OLD
// surface would read/write freed pmm frames, so a gen change triggers
// rescan() (re-target + re-capture + re-blit, no restore — the old
// surface is already gone).

const std = @import("std");
const fb = @import("fb.zig");
const pmm = @import("pmm");
const mmio = @import("mmio");
const net = @import("net");
const text = @import("text.zig");
const cursor = @import("cursor.zig");
const kms = @import("i915/kms.zig");

extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern var stdout: ?*anyopaque;

const WW: u32 = 320;
const WH: u32 = 200;
const TITLE_H: u32 = 22;
const BORDER: u32 = 2;
const HEAL_STRIDE: u64 = 8192;

// XRGB8888 — same packing as the console/i915 paths.
const C_BODY: u32 = 0x002A2F3A;
const C_TITLE: u32 = 0x003040C0;
const C_BORDER: u32 = 0x00D8DEE9;
const C_LABEL: u32 = 0x00F8F8F2;
const C_HINT: u32 = 0x008A93A6;

var live: bool = false;
var wx: u32 = 0;
var wy: u32 = 0;
var sw: u32 = 0; // scanout dims captured at create/rescan
var sh: u32 = 0;
var gen: u64 = 0; // fb.generation() the composites target
var dragging: bool = false;
var grab_dx: i32 = 0;
var grab_dy: i32 = 0;
var prev_held: bool = false;
var moves: u64 = 0;
var heal_n: u64 = 0;

// window backing — dmabuf (token owns the export) or pmm (phys+pages),
// one or the other, never both.
var buf: [*]volatile u32 = undefined;
var pitch: u32 = 0; // pixels per row
var tok: ?u32 = null;
var pphys: u64 = 0;
var ppages: usize = 0;

// retained under-window snapshot — WW*WH pixels, pitch WW, pmm frames.
var snap: [*]u32 = undefined;
var snap_ok: bool = false;

// sayU — dual-write one formatted line: serial AND the UDP mirror,
// same discipline as cursor.zig (the T590 oracle lives on the wire).
fn sayU(comptime fmt: []const u8, args: anytype) void {
    var b: [224]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    b[s.len] = 0;
    _ = fputs(@ptrCast(&b), stdout);
    net.mirror(s);
}

// ---- pixel helpers ---------------------------------------------------------

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
fn readPx(b: [*]volatile u32, p: u32, x: u32, y: u32) u32 {
    return b[@as(usize, @intCast(y)) * @as(usize, @intCast(p)) +
        @as(usize, @intCast(x))];
}
// 8x8 font into an arbitrary buffer — reuses text.zig's glyph table and
// its bit order (bit c of row r = column c), advance 9 like the console.
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

// ---- the window's own pixels ------------------------------------------------

fn paintWindow() void {
    fillRect(buf, pitch, 0, 0, WW, WH, C_BODY);
    frameRect(buf, pitch, WW, WH, BORDER, C_BORDER);
    // titlebar inside the border
    fillRect(buf, pitch, BORDER, BORDER, WW - 2 * BORDER, TITLE_H - 2 * BORDER, C_TITLE);
    drawText(buf, pitch, 10, BORDER + (TITLE_H - 2 * BORDER - 8) / 2, "kwin", C_LABEL);
    drawText(buf, pitch, 10, TITLE_H + 8, "drag me", C_HINT);
}

// ---- scanout target ---------------------------------------------------------

const Target = struct { px: [*]volatile u32, pitch: u32, w: u32, h: u32 };

fn target() ?Target {
    const s = fb.scanout() orelse return null;
    if (s.pitch < 4 or s.w == 0 or s.h == 0) return null;
    return .{
        .px = @ptrFromInt(@as(usize, @intCast(s.phys))),
        .pitch = s.pitch / 4,
        .w = s.w,
        .h = s.h,
    };
}

// ---- retained-restore damage -------------------------------------------------
// All three run with the cursor suspended — the scanout holds pure
// scene pixels (no XOR sprite) for the whole window rect. Element-wise
// row copies: the scanout side is volatile (device-mapped memory),
// @memcpy won't take the qualifier mix.

fn saveRect(t: Target) void {
    var y: u32 = 0;
    while (y < WH) : (y += 1) {
        const srow = @as(usize, @intCast(wy + y)) * @as(usize, @intCast(t.pitch)) +
            @as(usize, @intCast(wx));
        const drow = @as(usize, @intCast(y)) * @as(usize, WW);
        var x: usize = 0;
        while (x < @as(usize, WW)) : (x += 1) snap[drow + x] = t.px[srow + x];
    }
}
fn restoreRect(t: Target) void {
    var y: u32 = 0;
    while (y < WH) : (y += 1) {
        const drow = @as(usize, @intCast(wy + y)) * @as(usize, @intCast(t.pitch)) +
            @as(usize, @intCast(wx));
        const srow = @as(usize, @intCast(y)) * @as(usize, WW);
        var x: usize = 0;
        while (x < @as(usize, WW)) : (x += 1) t.px[drow + x] = snap[srow + x];
    }
}
fn blitWin(t: Target) void {
    var y: u32 = 0;
    while (y < WH) : (y += 1) {
        const drow = @as(usize, @intCast(wy + y)) * @as(usize, @intCast(t.pitch)) +
            @as(usize, @intCast(wx));
        const srow = @as(usize, @intCast(y)) * @as(usize, @intCast(pitch));
        var x: usize = 0;
        while (x < @as(usize, WW)) : (x += 1) t.px[drow + x] = buf[srow + x];
    }
}

fn ensureSnap() bool {
    if (snap_ok) return true;
    const bytes = @as(u64, WW) * WH * 4;
    const pages: usize = @intCast((bytes + 4095) / 4096);
    const phys = pmm.allocContiguous(pages, 1) orelse return false;
    if (!mmio.map(phys, bytes)) {
        _ = pmm.freeBlock(phys, pages);
        return false;
    }
    snap = @ptrFromInt(@as(usize, @intCast(phys)));
    snap_ok = true;
    return true;
}

// ---- backing alloc/free -------------------------------------------------------

fn allocBacking() ?[]const u8 {
    // dmabuf first when the KMS device is up — the M3 export seam. The
    // window never imports/flips; the token just owns a CPU-mapped
    // dumb buffer with real GTT residency.
    if (kms.device().up) {
        if (kms.dmabufCreate(WW, WH)) |t| {
            if (kms.dmabufMap(t)) |b| {
                if (b.map) |m| {
                    tok = t;
                    buf = m;
                    pitch = b.pitch / 4;
                    return "dmabuf";
                }
            }
            kms.dmabufUnref(t); // map refused — release the export
        }
    }
    // pmm backing — same pixels, same composite; used where no i915
    // device exists (QEMU, pre-'kms' shell). Named in the marker.
    const bytes = @as(u64, WW) * WH * 4;
    const pages: usize = @intCast((bytes + 4095) / 4096);
    const phys = pmm.allocContiguous(pages, 1) orelse return null;
    if (!mmio.map(phys, bytes)) {
        _ = pmm.freeBlock(phys, pages);
        return null;
    }
    pphys = phys;
    ppages = pages;
    buf = @ptrFromInt(@as(usize, @intCast(phys)));
    pitch = WW;
    return "pmm";
}

fn freeBacking() void {
    if (tok) |t| {
        kms.dmabufUnref(t); // refs 1->0 -> dumbDestroy frees the frames
        tok = null;
    } else if (pphys != 0) {
        _ = pmm.freeBlock(pphys, ppages);
        pphys = 0;
    }
    buf = undefined;
    pitch = 0;
}

// ---- create / destroy / rescan -------------------------------------------------

fn clampPos(nx: i64, ny: i64) struct { x: u32, y: u32 } {
    const maxX: i64 = @as(i64, @intCast(sw)) - WW;
    const maxY: i64 = @as(i64, @intCast(sh)) - WH;
    const x = @max(@as(i64, 0), @min(nx, maxX));
    const y = @max(@as(i64, 0), @min(ny, maxY));
    return .{ .x = @intCast(x), .y = @intCast(y) };
}

fn placeInitial(t: Target) void {
    const c = clampPos(@divTrunc(@as(i64, t.w), 2) - WW / 2,
        @divTrunc(@as(i64, t.h), 2) - WH / 2 + 24);
    wx = c.x;
    wy = c.y;
}

pub fn toggle() void {
    if (live) {
        destroy();
        return;
    }
    const t = target() orelse {
        sayU("KORU kwin: no scanout — fb backend absent or vgpu\n", .{});
        text.puts("kwin: no framebuffer\n");
        return;
    };
    if (t.w <= WW or t.h <= WH) {
        sayU("KORU kwin: screen {d}x{d} too small for 320x200\n", .{ t.w, t.h });
        text.puts("kwin: screen too small\n");
        return;
    }
    const kind = allocBacking() orelse {
        sayU("KORU kwin: backing alloc failed\n", .{});
        text.puts("kwin: alloc failed\n");
        return;
    };
    if (!ensureSnap()) {
        sayU("KORU kwin: snapshot alloc failed\n", .{});
        freeBacking();
        text.puts("kwin: alloc failed\n");
        return;
    }
    sw = t.w;
    sh = t.h;
    gen = fb.generation();
    placeInitial(t);
    paintWindow();

    cursor.compositeSuspend();
    saveRect(t);
    blitWin(t);
    cursor.compositeResume();

    live = true;
    dragging = false;
    prev_held = false;
    moves = 0;
    heal_n = 0;
    // readback proof — the composite either landed in the scanned
    // surface or it didn't; three pixels name it on the wire.
    const body = readPx(t.px, t.pitch, wx + WW / 2, wy + TITLE_H + 20);
    const bord = readPx(t.px, t.pitch, wx + 1, wy + 1);
    const titl = readPx(t.px, t.pitch, wx + WW / 2, wy + 4);
    sayU("KORU kwin create 320x200 @{d},{d} backing={s} body={x} border={x} title={x}\n",
        .{ wx, wy, kind, body, bord, titl });
    if (!cursor.isEnabled()) cursor.enable(); // drag needs the pointer
    text.puts("kwin: window up — press+drag inside it\n");
}

fn destroy() void {
    const t = target();
    // restore only onto the SAME generation we snapshotted — a flipped
    // scanout means the old frames may already be freed.
    if (t) |tt| {
        if (fb.generation() == gen) {
            cursor.compositeSuspend();
            restoreRect(tt);
            cursor.compositeResume();
        }
    }
    freeBacking();
    live = false;
    dragging = false;
    sayU("KORU kwin destroy @{d},{d}\n", .{ wx, wy });
    text.puts("kwin: window closed\n");
}

// gen changed under a live window (kms flip/modeset): the old surface
// is gone — re-target, re-capture under-content on the NEW surface,
// re-blit. No restore: there is nothing safe to restore onto.
fn rescan(t: Target) void {
    sw = t.w;
    sh = t.h;
    gen = fb.generation();
    const c = clampPos(@as(i64, wx), @as(i64, wy));
    wx = c.x;
    wy = c.y;
    cursor.compositeSuspend();
    saveRect(t);
    blitWin(t);
    cursor.compositeResume();
    sayU("KORU kwin rescan @{d},{d} on {d}x{d}\n", .{ wx, wy, sw, sh });
}

// ---- per-tick: drag input + heal ----------------------------------------------

pub fn tick() void {
    if (!live) return;
    const t = target() orelse return;
    if (fb.generation() != gen) {
        rescan(t);
        return;
    }
    if (cursor.isEnabled()) {
        const c = cursor.pos();
        const held = cursor.buttonsHeld() > 0;
        const inside = c.x >= @as(i32, @intCast(wx)) and
            c.x < @as(i32, @intCast(wx + WW)) and
            c.y >= @as(i32, @intCast(wy)) and
            c.y < @as(i32, @intCast(wy + WH));

        if (!dragging) {
            // drag starts only on the press EDGE inside the window — a
            // button held from outside doesn't capture on entry.
            if (held and !prev_held and inside) {
                dragging = true;
                grab_dx = c.x - @as(i32, @intCast(wx));
                grab_dy = c.y - @as(i32, @intCast(wy));
                moves = 0;
                sayU("KORU kwin drag @{d},{d}\n", .{ wx, wy });
            }
        } else {
            if (!held) {
                dragging = false;
                sayU("KORU kwin drop @{d},{d}\n", .{ wx, wy });
            } else {
                const want = clampPos(@as(i64, c.x) - @as(i64, grab_dx),
                    @as(i64, c.y) - @as(i64, grab_dy));
                if (want.x != wx or want.y != wy) {
                    cursor.compositeSuspend();
                    restoreRect(t);
                    wx = want.x;
                    wy = want.y;
                    saveRect(t);
                    blitWin(t);
                    cursor.compositeResume();
                    moves += 1;
                    if (moves == 1 or moves % 16 == 0)
                        sayU("KORU kwin move @{d},{d}\n", .{ wx, wy });
                }
            }
        }
        prev_held = held;
    } else {
        prev_held = false;
    }

    // heal stride — console output under the window is occluded;
    // re-blitting keeps the surface solid until the next real move.
    // Runs with or without the cursor: suspend/resume are no-ops then.
    heal_n += 1;
    if (heal_n >= HEAL_STRIDE) {
        heal_n = 0;
        if (!dragging) {
            cursor.compositeSuspend();
            blitWin(t);
            cursor.compositeResume();
        }
    }
}
