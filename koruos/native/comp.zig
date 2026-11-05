// koru/native comp — nativeCompositor: the display-server half of the
// native arm. surf.zig owns surface custody (pool, backings, lifetime);
// this module owns the SCENE those surfaces land in: z-order, damage,
// and the pointer.
//
// Rulings:
// - z, not present-order: present() is damage, never a paint order. A
//   lower surface presenting through a higher one's rect composites
//   UNDER it — the stack decides pixels, not the clock.
// - map at open: a surface enters the scene visible on its cleared
//   backing, so attach damages its rect immediately — a window you
//   never present is still a window.
// - retained mode: backings live in the provider, so a revealed region
//   repaints from what is retained — close() reveals what's beneath
//   without any client repaint; `expose` stays unemitted until backings
//   become client-painted on demand.
// - the pointer is compositor state: motion deltas accumulate into a
//   clamped position and the cursor is the scene's topmost layer,
//   revealed on the first delta (before deltas exist there is no
//   honest position). Buttons and keys pass through to the client —
//   focus/hit-test delivery is a later rung, named not faked.
// - repaint is poll-driven: the seam's drain advances the cursor and
//   composites on the caller's path; an IRQ never touches the fb path
//   (the virtqueue is not IRQ-context safe) — same discipline as the
//   input rings.
//
// Placement stays provider policy — every surface anchors at (40,40);
// stacking is the real change: index order in the layer stack IS z.
// Opaque pixels only — the seam carries no alpha channel today.

extern fn koruos_fb_info(out: *Info) callconv(.c) u8;
extern fn koruos_fb_px(x: u32, y: u32, color: u32) callconv(.c) u8;
extern fn koruos_fb_present(x: u32, y: u32, w: u32, h: u32) callconv(.c) u8;
extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;

const Info = extern struct {
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
};

const MAX_LAYERS = 8;
const ANCHOR: u32 = 40;
const BG: u32 = 0x00000000; // root scene — flat dark

var live: bool = false;
var W: u32 = 0;
var H: u32 = 0;

// ---- the layer stack ---------------------------------------------------
// index order IS z: attach appends on top, detach compacts down.
const Layer = struct {
    live: bool = false,
    buf: [*]u32 = undefined,
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
};
var layers = [_]Layer{.{}} ** MAX_LAYERS;
var top: usize = 0;

// topmost covering layer's pixel at (x,y), or the root color
fn pxAt(x: u32, y: u32) u32 {
    var i: usize = top;
    while (i > 0) {
        i -= 1;
        const l = &layers[i];
        if (l.live and x >= l.x and y >= l.y and x - l.x < l.w and y - l.y < l.h)
            return l.buf[(y - l.y) * l.w + (x - l.x)];
    }
    return BG;
}

// ---- the cursor --------------------------------------------------------
// an 11x18 arrow, bit per pixel — the compositor's own topmost layer.
const CURSOR = [18]u16{
    0x001, 0x003, 0x005, 0x009, 0x011, 0x021,
    0x041, 0x081, 0x101, 0x201, 0x7C1, 0x049,
    0x045, 0x043, 0x041, 0x040, 0x0C0, 0x040,
};
const CW: u32 = 11;
const CH: u32 = 18;

var cursor_on: bool = false;
var px_: i32 = 0; // pointer position — compositor-owned, clamped
var py_: i32 = 0;
var old_x: i32 = 0;
var old_y: i32 = 0;
var cursor_dirty: bool = false;

fn cursorPx(x: u32, y: u32) ?u32 {
    if (!cursor_on) return null; // no deltas yet — there is no pointer
    // arrow first — where it and the shadow land on the same pixel the
    // arrow wins; the shadow only darkens uncovered neighbors.
    const ax = x -% @as(u32, @intCast(px_));
    const ay = y -% @as(u32, @intCast(py_));
    if (ax < CW and ay < CH and (CURSOR[ay] >> @intCast(ax)) & 1 != 0)
        return 0x00FFFFFF;
    const sx = x -% @as(u32, @intCast(px_ + 1));
    const sy = y -% @as(u32, @intCast(py_ + 1));
    if (sx < CW and sy < CH and (CURSOR[sy] >> @intCast(sx)) & 1 != 0)
        return 0x00101010;
    return null;
}

// ---- damage ------------------------------------------------------------

fn composite(x: u32, y: u32, w: u32, h: u32) u8 {
    const x1 = @min(x + w, W);
    const y1 = @min(y + h, H);
    var yy = y;
    var nb: u64 = 0;
    while (yy < y1) : (yy += 1) {
        var xx = x;
        while (xx < x1) : (xx += 1) {
            const c = cursorPx(xx, yy) orelse pxAt(xx, yy);
            if (c != BG) nb += 1;
            _ = koruos_fb_px(xx, yy, c);
        }
    }
    koru_say("comp: paint ");
    koru_putdec(x1 - x);
    koru_say("x");
    koru_putdec(y1 - y);
    koru_say(" nb=");
    koru_putdec(nb);
    koru_say("\n");
    return koruos_fb_present(x, y, x1 - x, y1 - y);
}

// scene-space damage — clip to the scanout, repaint, commit
pub fn damage(x: u32, y: u32, w: u32, h: u32) u8 {
    if (!live) return 0;
    if (x >= W or y >= H) return 0;
    return composite(x, y, w, h);
}

// ---- the surface seam's calls ------------------------------------------

// attach enters the scene: fixed anchor, top of the stack, mapped
// (damaged) immediately on its cleared backing.
pub fn attach(buf: [*]u32, w: u32, h: u32, sx: *u32, sy: *u32) i32 {
    if (!live or top >= MAX_LAYERS) return -1;
    layers[top] = .{ .live = true, .buf = buf, .x = ANCHOR, .y = ANCHOR, .w = w, .h = h };
    sx.* = ANCHOR;
    sy.* = ANCHOR;
    koru_say("comp: attach ");
    koru_putdec(w);
    koru_say("x");
    koru_putdec(h);
    koru_say(" at ");
    koru_putdec(ANCHOR);
    koru_say(",");
    koru_putdec(ANCHOR);
    koru_say(" z=");
    koru_putdec(top);
    koru_say("\n");
    const slot: i32 = @intCast(top);
    top += 1;
    _ = damage(ANCHOR, ANCHOR, w, h);
    return slot;
}

// move relayers a surface to a new scene coord — damage the vacated
// rect AND the destination, so occluded regions beneath redraw too.
// Placement is the compositor's policy; the layer lookup is by backing
// (slots compact on detach — an index would stale).
pub fn move(buf: [*]u32, nx: u32, ny: u32, sx: *u32, sy: *u32) i32 {
    if (!live) return -1;
    for (layers[0..top], 0..) |*l, i| {
        if (l.buf == buf) {
            const rx = l.x;
            const ry = l.y;
            const rw = l.w;
            const rh = l.h;
            l.x = nx;
            l.y = ny;
            sx.* = nx;
            sy.* = ny;
            _ = damage(rx, ry, rw, rh);
            _ = damage(nx, ny, l.w, l.h);
            return @intCast(i);
        }
    }
    return -1;
}

// the scene's extent — a compositor needs it for cursor clamping and
// placement policy.
pub fn dims(sw: *u32, sh: *u32) void {
    sw.* = W;
    sh.* = H;
}

// detach leaves the scene: compact the stack, then damage the vacated
// rect — what's beneath repaints from its retained backing, no client
// involved.
pub fn detach(slot: u32) void {
    if (!live or slot >= top) return;
    const l = layers[slot];
    const rx = l.x;
    const ry = l.y;
    const rw = l.w;
    const rh = l.h;
    var i: usize = slot;
    while (i + 1 < top) : (i += 1) layers[i] = layers[i + 1];
    top -= 1;
    layers[top].live = false;
    koru_say("comp: detach z=");
    koru_putdec(slot);
    koru_say("\n");
    _ = damage(rx, ry, rw, rh);
}

// ---- pointer input (fan-out from the seam's drain) ---------------------

// a raw motion delta observed mid-drain — the compositor converts it to
// position; the caller still hands the delta to the client (v0 fan-out,
// not focus delivery).
pub fn feedMotion(dx: i32, dy: i32) void {
    if (!live) return;
    if (!cursor_on) {
        cursor_on = true;
        px_ = @intCast(W / 2);
        py_ = @intCast(H / 2);
        koru_say("comp: pointer revealed\n");
    }
    old_x = px_;
    old_y = py_;
    px_ = @max(0, @min(px_ + dx, @as(i32, @intCast(W)) - 1));
    py_ = @max(0, @min(py_ + dy, @as(i32, @intCast(H)) - 1));
    cursor_dirty = true;
}

// repaint the cursor if it moved — the union of old+new rects: the old
// spot composites back to the scene, the new draws the sprite.
pub fn flush() void {
    if (!cursor_dirty) return;
    cursor_dirty = false;
    const x0: u32 = @intCast(@min(old_x, px_));
    const y0: u32 = @intCast(@min(old_y, py_));
    const x1: u32 = @intCast(@max(old_x, px_) + @as(i32, @intCast(CW)));
    const y1: u32 = @intCast(@max(old_y, py_) + @as(i32, @intCast(CH)));
    _ = composite(x0, y0, x1 - x0, y1 - y0);
}

// ---- init ---------------------------------------------------------------

// The compositor takes ownership of the scanout: read the mode, then
// one full-screen damage — the root scene's first paint.
pub fn init() void {
    var info: Info = undefined;
    if (koruos_fb_info(&info) == 0) return;
    W = info.width;
    H = info.height;
    live = true;
    koru_say("comp: compositor live ");
    koru_putdec(W);
    koru_say("x");
    koru_putdec(H);
    koru_say("\n");
    _ = damage(0, 0, W, H);
}
