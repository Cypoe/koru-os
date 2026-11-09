// koru/native/cmdview — the MC-3 CmdView backend: rasterizes an oshun
// solver's render-command stream into a window backing (XRGB8888).
//
// What this is: the display-list -> pixels half of "markup -> spec ->
// solver -> CmdView -> paint". The stream is produced OFF-TARGET by
// the real component path (oshun/koruos/ui_probe.k: libs/ui panelx/
// text + libs/clay solver -> clay:each -> ! cmd drain, printed as
// ui_cmds.txt, embedded below). On-target there is no solver — clay
// needs CoreText/libc; the honest seam is "solver emits commands,
// backend paints them", which is exactly what metal does on macOS.
//
// Command vocabulary (clay.h ordinals, same as CmdView.kind):
//   1 RECT    — fill + per-corner radius (ctl..cbr), src-over alpha
//   2 BORDER  — counted skip (v1: no border emitter — named gap)
//   3 TEXT    — tx string, 8x8 font at integer scale, centered in box
//   4 IMAGE   — counted skip (no image producer on-target — named gap)
//   5/6       — SCISSOR push/pop clip rect
//   9 CUSTOM  — counted skip
// Anything else: counted skip. Skips are reported via stats(), never
// silent — a stream the backend can't paint is a named gap, not a
// wrong pixel.
//
// Text honesty: the 8x8 cell font's advance (9px/char) is wider than
// CoreText's measure the solver used for the cmd box, so glyphs are
// CENTERED in the box and may overflow it horizontally — named, not
// hidden. Scale: fs>=13 -> 2x, else 1x (nearest honest size).
//
// Live slots (producer contract, ui_probe.k):
//   ud==2  — the button's own commands: hit region for hover state
//   ud==90 — the counter text: kernel rewrites tx digits per tick
// Two streams ==A==/==B== = normal/hot palettes; the kernel picks per
// pointer-inside-button — the gallery's state->restyle->redraw idiom.

const std = @import("std");
const text = @import("text.zig");
const net = @import("net");

const blob = @embedFile("ui_cmds.txt");

pub const MAX_CMDS = 32;
pub const HIT_EID: i64 = 2;
pub const LIVE_EID: i64 = 90;
// window-body placement inside the 320x200 backing (win.zig TITLE_H/
// BORDER): canvas 316x174 at backing offset (2,24).
pub const OX: i32 = 2;
pub const OY: i32 = 24;
pub const CW: u32 = 316;
pub const CH: u32 = 174;

const Cmd = struct {
    kind: i64 = 0,
    x: f64 = 0, y: f64 = 0, w: f64 = 0, h: f64 = 0,
    r: u8 = 0, g: u8 = 0, b: u8 = 0, a: u8 = 255,
    fs: f64 = 0,
    ud: i64 = 0,
    ctl: f64 = 0, ctr: f64 = 0, cbl: f64 = 0, cbr: f64 = 0,
    tx: [48]u8 = @splat(0),
    txlen: usize = 0,
};

var streams: [2][MAX_CMDS]Cmd = undefined;
var ns: [2]usize = .{ 0, 0 };
var ready: bool = false;
var skipped: u64 = 0;
var bad_lines: u64 = 0;

fn sayU(comptime fmt: []const u8, args: anytype) void {
    var b: [192]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    net.mirror(s);
}

// ---- parse -----------------------------------------------------------------

fn nextTok(line: []const u8, pos: *usize) ?[]const u8 {
    var i = pos.*;
    while (i < line.len and line[i] == ' ') i += 1;
    if (i >= line.len) return null;
    const s = i;
    while (i < line.len and line[i] != ' ') i += 1;
    pos.* = i;
    return line[s..i];
}

fn f64tok(t: []const u8) f64 {
    return std.fmt.parseFloat(f64, t) catch 0.0;
}

pub fn ensure() void {
    if (ready) return;
    ready = true;
    var si: usize = 0;
    var cur = [2]usize{ 0, 0 };
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "==A==")) { si = 0; continue; }
        if (std.mem.eql(u8, line, "==B==")) { si = 1; continue; }
        if (std.mem.eql(u8, line, "==END==")) break;
        if (line[0] != 'C') { bad_lines += 1; continue; }
        if (cur[si] >= MAX_CMDS) { bad_lines += 1; continue; }
        var pos: usize = 1; // skip 'C'
        const t_kind = nextTok(line, &pos) orelse { bad_lines += 1; continue; };
        var c = Cmd{};
        c.kind = std.fmt.parseInt(i64, t_kind, 10) catch { bad_lines += 1; continue; };
        // x y w h r g b a fs ud ctl ctr cbl cbr — 14 numeric tokens
        const nums = [14][]const u8{
            nextTok(line, &pos) orelse "", nextTok(line, &pos) orelse "",
            nextTok(line, &pos) orelse "", nextTok(line, &pos) orelse "",
            nextTok(line, &pos) orelse "", nextTok(line, &pos) orelse "",
            nextTok(line, &pos) orelse "", nextTok(line, &pos) orelse "",
            nextTok(line, &pos) orelse "", nextTok(line, &pos) orelse "",
            nextTok(line, &pos) orelse "", nextTok(line, &pos) orelse "",
            nextTok(line, &pos) orelse "", nextTok(line, &pos) orelse "",
        };
        c.x = f64tok(nums[0]); c.y = f64tok(nums[1]);
        c.w = f64tok(nums[2]); c.h = f64tok(nums[3]);
        c.r = @intFromFloat(@round(f64tok(nums[4]) * 255.0));
        c.g = @intFromFloat(@round(f64tok(nums[5]) * 255.0));
        c.b = @intFromFloat(@round(f64tok(nums[6]) * 255.0));
        c.a = @intFromFloat(@round(f64tok(nums[7]) * 255.0));
        c.fs = f64tok(nums[8]);
        c.ud = std.fmt.parseInt(i64, nums[9], 10) catch 0;
        c.ctl = f64tok(nums[10]); c.ctr = f64tok(nums[11]);
        c.cbl = f64tok(nums[12]); c.cbr = f64tok(nums[13]);
        // tx = rest of line after the last numeric token
        var j = pos;
        while (j < line.len and line[j] == ' ') j += 1;
        if (j < line.len) {
            const tl = @min(line.len - j, c.tx.len);
            @memcpy(c.tx[0..tl], line[j .. j + tl]);
            c.txlen = tl;
        }
        streams[si][cur[si]] = c;
        cur[si] += 1;
    }
    ns = cur;
    sayU("KORU cmdview: A={d} B={d} bad={d}\n", .{ ns[0], ns[1], bad_lines });
}

pub fn count(si: usize) usize {
    return ns[si];
}

// ---- live slot ---------------------------------------------------------------

// rewrite the counter text in BOTH streams (ud==LIVE_EID) — "t=NNNN"
pub fn setCounter(v: u32) void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "t={d:0>4}", .{v}) catch return;
    for (0..2) |si| {
        for (streams[si][0..ns[si]]) |*c| {
            if (c.ud != LIVE_EID or c.kind != 3) continue;
            const tl = @min(s.len, c.tx.len);
            @memset(c.tx[0..], 0);
            @memcpy(c.tx[0..tl], s[0..tl]);
            c.txlen = tl;
        }
    }
}

// pointer (canvas coords) inside the hit region? Tests stream A's
// ud==HIT_EID commands — the hot stream shares identical geometry.
pub fn hitButton(lx: i32, ly: i32) bool {
    ensure();
    const x = @as(f64, @floatFromInt(lx));
    const y = @as(f64, @floatFromInt(ly));
    for (streams[0][0..ns[0]]) |*c| {
        if (c.ud != HIT_EID) continue;
        if (x >= c.x and y >= c.y and x < c.x + c.w and y < c.y + c.h) return true;
    }
    return false;
}

// ---- raster ------------------------------------------------------------------

const Clip = struct { x: f64 = 0, y: f64 = 0, w: f64 = 0, h: f64 = 0, on: bool = false };

// canvas coord (cx,cy) -> backing px, src-over alpha blend
fn px(buf: [*]volatile u32, pitch: u32, bw: u32, bh: u32,
    cx: i32, cy: i32, r: u8, g: u8, b: u8, a: u8) void
{
    const bx = OX + cx;
    const by = OY + cy;
    if (bx < 0 or by < 0 or @as(u32, @intCast(bx)) >= bw or @as(u32, @intCast(by)) >= bh) return;
    const i = @as(usize, @intCast(by)) * @as(usize, @intCast(pitch)) + @as(usize, @intCast(bx));
    if (a >= 255) {
        buf[i] = (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
        return;
    }
    if (a == 0) return;
    const d = buf[i];
    const dr: u32 = (d >> 16) & 0xFF;
    const dg: u32 = (d >> 8) & 0xFF;
    const db: u32 = d & 0xFF;
    const sa = @as(u32, a);
    const inv = 255 - sa;
    const nr = (@as(u32, r) * sa + dr * inv) / 255;
    const ng = (@as(u32, g) * sa + dg * inv) / 255;
    const nb = (@as(u32, b) * sa + db * inv) / 255;
    buf[i] = (nr << 16) | (ng << 8) | nb;
}

fn inClip(c: *const Clip, x: f64, y: f64) bool {
    if (!c.on) return true;
    return x >= c.x and y >= c.y and x < c.x + c.w and y < c.y + c.h;
}

fn rectCmd(buf: [*]volatile u32, pitch: u32,
    c: *const Cmd, clip: *const Clip) void
{
    const x0 = @max(0, @as(i32, @intFromFloat(@floor(c.x))));
    const y0 = @max(0, @as(i32, @intFromFloat(@floor(c.y))));
    const x1 = @min(@as(i32, @intCast(CW)), @as(i32, @intFromFloat(@ceil(c.x + c.w))));
    const y1 = @min(@as(i32, @intCast(CH)), @as(i32, @intFromFloat(@ceil(c.y + c.h))));
    var yy = y0;
    while (yy < y1) : (yy += 1) {
        var xx = x0;
        while (xx < x1) : (xx += 1) {
            const fx = @as(f64, @floatFromInt(xx)) + 0.5 - c.x;
            const fy = @as(f64, @floatFromInt(yy)) + 0.5 - c.y;
            if (!inClip(clip, @as(f64, @floatFromInt(xx)) + 0.5, @as(f64, @floatFromInt(yy)) + 0.5)) continue;
            // per-corner radius: inside a corner box -> quarter-arc test
            var skip = false;
            if (c.ctl > 0 and fx < c.ctl and fy < c.ctl) {
                const dx = fx - c.ctl;
                const dy = fy - c.ctl;
                skip = dx * dx + dy * dy > c.ctl * c.ctl;
            } else if (c.ctr > 0 and fx > c.w - c.ctr and fy < c.ctr) {
                const dx = fx - (c.w - c.ctr);
                const dy = fy - c.ctr;
                skip = dx * dx + dy * dy > c.ctr * c.ctr;
            } else if (c.cbl > 0 and fx < c.cbl and fy > c.h - c.cbl) {
                const dx = fx - c.cbl;
                const dy = fy - (c.h - c.cbl);
                skip = dx * dx + dy * dy > c.cbl * c.cbl;
            } else if (c.cbr > 0 and fx > c.w - c.cbr and fy > c.h - c.cbr) {
                const dx = fx - (c.w - c.cbr);
                const dy = fy - (c.h - c.cbr);
                skip = dx * dx + dy * dy > c.cbr * c.cbr;
            }
            if (!skip) px(buf, pitch, CW + 4, CH + 24, xx, yy, c.r, c.g, c.b, c.a);
        }
    }
}

fn textCmd(buf: [*]volatile u32, pitch: u32,
    c: *const Cmd, clip: *const Clip) void
{
    if (c.txlen == 0) return;
    const scale: i32 = if (c.fs >= 13.0) 2 else 1;
    const adv = 9 * scale;
    const textw = @as(i32, @intCast(c.txlen)) * adv;
    const texth = 8 * scale;
    const gx = @as(i32, @intFromFloat(@round(c.x + (c.w - @as(f64, @floatFromInt(textw))) / 2.0)));
    const gy = @as(i32, @intFromFloat(@round(c.y + (c.h - @as(f64, @floatFromInt(texth))) / 2.0)));
    var cx = gx;
    for (c.tx[0..c.txlen]) |ch| {
        if (ch >= 0x20 and ch < 0x80) {
            const g = text.font[ch & 0x7F];
            var r: usize = 0;
            while (r < 8) : (r += 1) {
                var col: usize = 0;
                while (col < 8) : (col += 1) {
                    if (((g[r] >> @intCast(col)) & 1) != 0) {
                        var sy: i32 = 0;
                        while (sy < scale) : (sy += 1) {
                            var sx: i32 = 0;
                            while (sx < scale) : (sx += 1) {
                                const qx = cx + @as(i32, @intCast(col)) * scale + sx;
                                const qy = gy + @as(i32, @intCast(r)) * scale + sy;
                                if (!inClip(clip, @as(f64, @floatFromInt(qx)) + 0.5, @as(f64, @floatFromInt(qy)) + 0.5)) continue;
                                px(buf, pitch, CW + 4, CH + 24, qx, qy, c.r, c.g, c.b, c.a);
                            }
                        }
                    }
                }
            }
        }
        cx += adv;
    }
}

// paint stream `si` into the window backing. The backing is pitch-strided
// and CW+4 x CH+24 covers the body region (ox/oy baked into px()).
pub fn render(buf: [*]volatile u32, pitch: u32, si: usize) void {
    ensure();
    var stack: [8]Clip = undefined;
    var sp: usize = 0;
    var clip = Clip{ .on = false };
    for (streams[si][0..ns[si]]) |*c| {
        switch (c.kind) {
            1 => rectCmd(buf, pitch, c, &clip),
            3 => textCmd(buf, pitch, c, &clip),
            5 => { // SCISSOR_START — push clip intersected with parent
                if (sp < stack.len) {
                    var nc = Clip{ .x = c.x, .y = c.y, .w = c.w, .h = c.h, .on = true };
                    if (clip.on) {
                        const nx = @max(nc.x, clip.x);
                        const ny = @max(nc.y, clip.y);
                        const nx1 = @min(nc.x + nc.w, clip.x + clip.w);
                        const ny1 = @min(nc.y + nc.h, clip.y + clip.h);
                        nc = .{ .x = nx, .y = ny, .w = @max(0.0, nx1 - nx), .h = @max(0.0, ny1 - ny), .on = true };
                    }
                    stack[sp] = nc;
                    sp += 1;
                    clip = nc;
                } else skipped += 1;
            },
            6 => { // SCISSOR_END — pop
                if (sp > 0) {
                    sp -= 1;
                    clip = if (sp == 0) Clip{ .on = false } else stack[sp - 1];
                } else skipped += 1;
            },
            else => skipped += 1, // BORDER/IMAGE/CUSTOM/unknown — named gaps
        }
    }
}

pub fn stats() struct { skipped: u64, bad: u64, n0: usize, n1: usize } {
    return .{ .skipped = skipped, .bad = bad_lines, .n0 = ns[0], .n1 = ns[1] };
}
