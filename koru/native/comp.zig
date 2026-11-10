// koru/native comp — the scene core: z-ordered layer stack, coalesced
// damage, window objects (focus/raise/drag), placement authority, and
// the damage->composite primitives the present backends drive.
//
// MC-1 per session/m1-dumb-kms/COMPOSITOR-DESIGN.md: ONE scene core on
// the live shell path. This module stays dependency-free (externs only)
// — it is a -M module with no deps, so cursor/kms/text state arrives
// through feedPointer/cursorAttach/sink callbacks, never imports.
//
// Rulings (carried from the contract):
// - z decides pixels, never present order. Layers carry an explicit
//   monotonic z; raise() re-stamps it. Dead slots are never compacted —
//   handles (surf.zig slots, win.zig windows) stay valid until close.
// - Damage is a coalesced rect list, not immediate repaint: every
//   mutation unions scene-space rects into `pending`; the present layer
//   drains once per tick and composites ALL of it in one pass. This is
//   the flicker fix — one correct repaint per tick, revealed regions
//   repaint from retained backings.
// - Window != position: drag/input calls placeRequest -> decide() ->
//   set x/y. v1 policy = float (clamp to scene). A tiling policy later
//   implements the same decide without compositor rework.
// - Surface != window: kind=.surface layers (surf.zig clients) have no
//   chrome/focus; kind=.window adds WinState; kind=.root is the console
//   backing — a retained layer, so covering console text no longer
//   destroys it (the occlusion loss that forced kwin's heal stride).
// - The cursor IS a layer: pointer state arrives via feedPointer (which
//   place()s the cursor layer — damage-tracked like every layer), the
//   arrow backing via cursorAttach. CURSOR_CLEAR px are transparent.
// - Opaque XRGB8888 only — the seam carries no alpha.

extern fn koruos_fb_info(out: *Info) callconv(.c) u8;
extern fn koruos_fb_scanout(out: *ScanoutInfo) callconv(.c) u8;
extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;

const Info = extern struct {
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
};
const ScanoutInfo = extern struct {
    phys: u64,
    pitch: u32,
    w: u32,
    h: u32,
};

pub const MAX_LAYERS = 16;
const BG: u32 = 0x00000000; // root fallback when no root layer is live

// cursor layer contract: px == CURSOR_CLEAR is transparent (the pixel
// resolves to whatever layer sits below); any other value composites
// verbatim. The layer's z is pinned above all z_next churn.
pub const CURSOR_CLEAR: u32 = 0;
const CURSOR_Z: u32 = 0xFFFF_0000;

pub const Kind = enum { root, window, surface, cursor };

// compositor-side window state — chrome geometry for hit-testing,
// focus, drag. Position is NOT here: layers own x/y through the
// placement authority.
pub const WinState = struct {
    title_h: u32 = 0, // titlebar height in backing px; 0 = no chrome split
    focused: bool = false,
    dragging: bool = false,
    grab_dx: i32 = 0,
    grab_dy: i32 = 0,
    owner: usize = 0, // producer cookie (win.zig pool index) — comp never derefs
    key_intake: bool = false, // keyboard routing stub — v1: none declare
};

const Layer = struct {
    live: bool = false,
    z: u32 = 0, // monotonic — higher is on top; explicit, not index order
    kind: Kind = .surface,
    buf: [*]u32 = undefined,
    pitch: u32 = 0, // pixels per row (may differ from w — dmabuf pitch)
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    win: WinState = .{},
};
var layers = [_]Layer{.{}} ** MAX_LAYERS;
var z_next: u32 = 1;

var live: bool = false;
var W: u32 = 0;
var H: u32 = 0;

// ---- damage accumulator -------------------------------------------------
// Bounded rect list: union-merge on insert (overlap or edge-touch ->
// bounding box), clip to scene; overflow degrades to whole-scene damage
// — the honest degenerate, never a dropped rect.

pub const MAX_DMG = 32;
pub const Rect = struct { x: u32 = 0, y: u32 = 0, w: u32 = 0, h: u32 = 0 };

pub const Acc = struct {
    rects: [MAX_DMG]Rect = @splat(.{}),
    n: usize = 0,
    full: bool = false,

    pub fn empty(a: *const Acc) bool {
        return !a.full and a.n == 0;
    }
    pub fn clear(a: *Acc) void {
        a.n = 0;
        a.full = false;
    }
    // scene-space damage — clip, merge, or degrade to full.
    pub fn add(a: *Acc, r: Rect, sw: u32, sh: u32) void {
        if (a.full) return;
        if (r.x >= sw or r.y >= sh or r.w == 0 or r.h == 0) return;
        const x1 = @min(r.x + r.w, sw);
        const y1 = @min(r.y + r.h, sh);
        var m = Rect{ .x = r.x, .y = r.y, .w = x1 - r.x, .h = y1 - r.y };
        // merge passes: each merge can create a new touch, so rescan
        // until stable (bounded by n — every merge shrinks the list).
        var merged = true;
        while (merged) {
            merged = false;
            for (a.rects[0..a.n], 0..) |*o, i| {
                const touch = m.x <= o.x + o.w and o.x <= m.x + m.w and
                    m.y <= o.y + o.h and o.y <= m.y + m.h;
                if (!touch) continue;
                const nx = @min(m.x, o.x);
                const ny = @min(m.y, o.y);
                const nx1 = @max(m.x + m.w, o.x + o.w);
                const ny1 = @max(m.y + m.h, o.y + o.h);
                m = .{ .x = nx, .y = ny, .w = nx1 - nx, .h = ny1 - ny };
                // remove o: swap-last
                a.rects[i] = a.rects[a.n - 1];
                a.n -= 1;
                merged = true;
                break;
            }
        }
        if (a.n >= MAX_DMG) {
            a.full = true; // overflow — repaint everything, honestly
            a.n = 0;
            return;
        }
        a.rects[a.n] = m;
        a.n += 1;
    }
};

var pending: Acc = .{};

fn say(comptime s: [*:0]const u8) void {
    koru_say(s);
}
fn sayU(comptime fmt_msg: []const u8, v: u64) void {
    _ = fmt_msg;
    koru_putdec(v);
}

// ---- pointer --------------------------------------------------------------
// cursor.zig owns the device side; shell feeds the sprite rect + buttons
// once per tick via feedPointer. comp owns the semantics: press-edge
// hit-test, focus/raise, drag -> placeRequest, and the sprite overlay
// inside composite.

var ptr_x: i32 = 0;
var ptr_y: i32 = 0;
var ptr_on: bool = false; // cursor enabled — sprite visible, input live
var ptr_buttons: u32 = 0;
var ptr_prev_held: bool = false;
var drag_handle: i32 = -1;

var cur_handle: i32 = -1; // cursor layer slot — -1 until cursorAttach

pub fn feedPointer(x: i32, y: i32, on: bool, buttons: u32) void {
    const was_on = ptr_on;
    ptr_x = x;
    ptr_y = y;
    ptr_on = on;
    ptr_buttons = buttons;
    // the cursor is a scene layer now — place() damages the vacated +
    // destination rects itself; a visibility flip repaints its rect so
    // hide/show composites correctly. pxIn/collectLayers gate .cursor
    // layers on ptr_on, so "off" needs only the repaint.
    if (cur_handle >= 0) {
        const l = &layers[@intCast(cur_handle)];
        if (on != was_on) _ = damage(l.x, l.y, l.w, l.h);
        if (on) place(@intCast(cur_handle), x, y);
    }
}

// cursorAttach — the pointer's scene presence is a topmost layer with
// CURSOR_CLEAR transparency, not an XOR overlay. Called once at shell
// init with cursor.zig's expanded arrow backing.
pub fn cursorAttach(buf: [*]u32, pitch: u32, w: u32, h: u32) i32 {
    var sx: u32 = 0;
    var sy: u32 = 0;
    const hnd = attach(buf, pitch, w, h, 0, 0, .cursor, 0, &sx, &sy);
    if (hnd >= 0) {
        cur_handle = hnd;
        layers[@intCast(hnd)].z = CURSOR_Z; // above all z_next churn
    }
    return hnd;
}

pub fn pointerOn() bool {
    return ptr_on;
}

// feedMotion — kbd.zig's input-queue seam calls this on the dormant
// fullBoot path. On the live shell path the pointer arrives via
// cursor.zig -> feedPointer; relative motion events here are ignored
// (named: no scene consumer for raw dx/dy).
pub fn feedMotion(dx: i32, dy: i32) void {
    _ = dx;
    _ = dy;
}

// ---- scene pixel resolve ---------------------------------------------------

fn layerHit(l: *const Layer, x: u32, y: u32) bool {
    return x >= l.x and y >= l.y and x - l.x < l.w and y - l.y < l.h;
}

// topmost-wins over a candidate list sorted z-desc — first hit returns.
fn pxIn(x: u32, y: u32, cands: []const *Layer) u32 {
    var c: u32 = BG;
    for (cands) |l| {
        if (!layerHit(l, x, y)) continue;
        if (l.kind == .cursor) {
            if (!ptr_on) continue; // hidden — resolve what's beneath
            const px = l.buf[@as(usize, @intCast(y - l.y)) *
                @as(usize, @intCast(l.pitch)) +
                @as(usize, @intCast(x - l.x))];
            if (px == CURSOR_CLEAR) continue; // transparent — next layer
            c = px;
            break;
        }
        c = l.buf[@as(usize, @intCast(y - l.y)) * @as(usize, @intCast(l.pitch)) +
            @as(usize, @intCast(x - l.x))];
        break; // topmost hit wins — c stays BG when nothing covers
    }
    return c;
}

// ---- composite --------------------------------------------------------------
// Paint one scene rect into a target buffer. Candidates = live layers
// intersecting the rect, sorted z-desc — pxIn early-outs on topmost.

pub const Target = struct {
    px: [*]volatile u32,
    pitch: u32, // pixels per row
    w: u32,
    h: u32,
};

fn buildCands(rect: Rect, cands: *[MAX_LAYERS]*Layer) usize {
    var n: usize = 0;
    for (layers[0..]) |*l| {
        if (!l.live) continue;
        const ix = l.x < rect.x + rect.w and rect.x < l.x + l.w;
        const iy = l.y < rect.y + rect.h and rect.y < l.y + l.h;
        if (!ix or !iy) continue;
        // insertion sort z-desc
        var i = n;
        while (i > 0 and cands[i - 1].z < l.z) : (i -= 1) cands[i] = cands[i - 1];
        cands[i] = l;
        n += 1;
    }
    return n;
}

pub fn compositeRect(t: *const Target, x: u32, y: u32, w: u32, h: u32) void {
    if (!live or w == 0 or h == 0) return;
    const x1 = @min(@min(x + w, W), t.w);
    const y1 = @min(@min(y + h, H), t.h);
    if (x >= x1 or y >= y1) return;
    var cands: [MAX_LAYERS]*Layer = undefined;
    const nc = buildCands(.{ .x = x, .y = y, .w = x1 - x, .h = y1 - y }, &cands);
    const cs = cands[0..nc];
    var yy = y;
    while (yy < y1) : (yy += 1) {
        const drow = @as(usize, @intCast(yy)) * @as(usize, @intCast(t.pitch)) +
            @as(usize, @intCast(x));
        var xx = x;
        while (xx < x1) : (xx += 1) {
            t.px[drow + @as(usize, @intCast(xx - x))] = pxIn(xx, yy, cs);
        }
    }
}

// composite every rect in an accumulator — the present backends' one
// call per painted buffer.
pub fn compositeAcc(t: *const Target, acc: *const Acc) void {
    if (acc.full) {
        compositeRect(t, 0, 0, W, H);
        return;
    }
    for (acc.rects[0..acc.n]) |r| compositeRect(t, r.x, r.y, r.w, r.h);
}

// ---- damage ingress ---------------------------------------------------------

// scene-space damage — clip to scene, union into pending. Returns 1
// (accepted) for the surf.zig present() contract.
pub fn damage(x: u32, y: u32, w: u32, h: u32) u8 {
    if (!live) return 0;
    pending.add(.{ .x = x, .y = y, .w = w, .h = h }, W, H);
    return 1;
}

// text.zig sink callback — console cell damage in scene coords.
pub fn sceneDamage(x: u32, y: u32, w: u32, h: u32) void {
    _ = damage(x, y, w, h);
}

// backing-rect -> scene-rect damage for a live layer (producer updates:
// titlebar focus repaint etc.). bx,by,bw,bh are backing coords.
pub fn damageLayer(handle: i32, bx: u32, by: u32, bw: u32, bh: u32) void {
    if (!live or handle < 0 or @as(usize, @intCast(handle)) >= MAX_LAYERS) return;
    const l = &layers[@intCast(handle)];
    if (!l.live) return;
    _ = damage(l.x + bx, l.y + by, bw, bh);
}

// drain the pending accumulator — the present layer calls once per
// tick and fans the rects into its per-buffer accumulators (or paints
// them directly in immediate mode).
pub fn takePending() Acc {
    const d = pending;
    pending.clear();
    return d;
}

// ---- placement authority -----------------------------------------------------
// The ONLY verb that moves a layer. v1 policy = float: clamp into the
// scene, free position. A tiling policy later implements decide()
// differently — drag/input never learns the difference.

fn decide(nx: i64, ny: i64, w: u32, h: u32) struct { x: u32, y: u32 } {
    const maxX: i64 = @as(i64, @intCast(W)) - @as(i64, @intCast(w));
    const maxY: i64 = @as(i64, @intCast(H)) - @as(i64, @intCast(h));
    const cx = if (maxX < 0) 0 else maxX;
    const cy = if (maxY < 0) 0 else maxY;
    return .{
        .x = @intCast(@max(@as(i64, 0), @min(nx, cx))),
        .y = @intCast(@max(@as(i64, 0), @min(ny, cy))),
    };
}

// place a layer through the authority — damages vacated + destination
// so occluded regions beneath repaint from retained backings.
fn place(handle: usize, nx: i64, ny: i64) void {
    const l = &layers[handle];
    const c = decide(nx, ny, l.w, l.h);
    if (c.x == l.x and c.y == l.y) return;
    const ox = l.x;
    const oy = l.y;
    l.x = c.x;
    l.y = c.y;
    _ = damage(ox, oy, l.w, l.h);
    _ = damage(l.x, l.y, l.w, l.h);
}

// ---- layer verbs ---------------------------------------------------------------

// attach a producer backing into the scene. kind selects the contract:
// .root = console (attach FIRST — lowest z), .window = chrome+focus,
// .surface = bare client surface (surf.zig). dx,dy is the DESIRED scene
// pos — decide() has final say. Returns the layer handle (stable slot
// index) or -1.
pub fn attach(buf: [*]u32, pitch: u32, w: u32, h: u32, dx: u32, dy: u32,
    kind: Kind, owner: usize, sx: *u32, sy: *u32) i32
{
    if (!live) return -1;
    var slot: ?usize = null;
    for (layers[0..], 0..) |*l, i| {
        if (!l.live) {
            slot = i;
            break;
        }
    }
    const s = slot orelse {
        say("comp: attach refused — layer table full\n");
        return -1;
    };
    const l = &layers[s];
    l.* = .{
        .live = true,
        .z = if (kind == .root) 0 else z_next,
        .kind = kind,
        .buf = buf,
        .pitch = if (pitch == 0) w else pitch,
        .w = w,
        .h = h,
    };
    if (kind != .root) z_next += 1;
    if (kind == .window) l.win.owner = owner;
    place(s, @intCast(dx), @intCast(dy));
    sx.* = l.x;
    sy.* = l.y;
    say("comp: attach ");
    sayU("", w);
    say("x");
    sayU("", h);
    say(" z=");
    sayU("", l.z);
    say("\n");
    _ = damage(l.x, l.y, l.w, l.h); // map at open — visible on arrival
    return @intCast(s);
}

// the console root layer — full-scene backing, bottom of the stack.
pub fn attachRoot(buf: [*]u32, pitch: u32, w: u32, h: u32) i32 {
    var sx: u32 = 0;
    var sy: u32 = 0;
    return attach(buf, pitch, w, h, 0, 0, .root, 0, &sx, &sy);
}

// window open — attach + WinState + focus/raise (a new window takes
// attention; click-to-focus remains the only other path).
pub fn windowOpen(buf: [*]u32, pitch: u32, w: u32, h: u32,
    dx: u32, dy: u32, title_h: u32, owner: usize) i32
{
    var sx: u32 = 0;
    var sy: u32 = 0;
    const h_ = attach(buf, pitch, w, h, dx, dy, .window, owner, &sx, &sy);
    if (h_ < 0) return -1;
    const l = &layers[@intCast(h_)];
    l.win.title_h = title_h;
    l.win.owner = owner;
    focusWindow(@intCast(h_));
    raiseLayer(@intCast(h_));
    say("comp: window open z=");
    sayU("", l.z);
    say("\n");
    return h_;
}

// move — surf.zig's placement verb, through the same authority.
pub fn move(buf: [*]u32, nx: u32, ny: u32, sx: *u32, sy: *u32) i32 {
    if (!live) return -1;
    for (layers[0..], 0..) |*l, i| {
        if (l.live and l.buf == buf) {
            place(i, @intCast(nx), @intCast(ny));
            sx.* = l.x;
            sy.* = l.y;
            return @intCast(i);
        }
    }
    return -1;
}

// detach by handle — mark dead, damage the vacated rect (what's beneath
// repaints from retained backings). No compaction: handles stay put.
pub fn detach(handle: i32) void {
    if (!live or handle < 0 or @as(usize, @intCast(handle)) >= MAX_LAYERS) return;
    const l = &layers[@intCast(handle)];
    if (!l.live) return;
    const rx = l.x;
    const ry = l.y;
    const rw = l.w;
    const rh = l.h;
    l.live = false;
    l.win = .{};
    if (drag_handle == handle) {
        drag_handle = -1;
    }
    say("comp: detach z=");
    sayU("", l.z);
    say("\n");
    _ = damage(rx, ry, rw, rh);
}

pub fn dims(sw: *u32, sh: *u32) void {
    sw.* = W;
    sh.* = H;
}

// scene dims follow the scanout — a modeset/rebase changes fb geometry
// (koruos_fb_info reports the live surface). Layers re-clamp through
// the placement authority so nothing is left offscene; damage clips to
// the NEW bounds. Called by present on fb.generation() change.
pub fn syncDims() void {
    var info: Info = undefined;
    if (koruos_fb_info(&info) == 0) return;
    if (info.width == W and info.height == H) return;
    W = info.width;
    H = info.height;
    say("comp: scene dims -> ");
    koru_putdec(W);
    say("x");
    koru_putdec(H);
    say("\n");
    for (layers[0..], 0..) |*l, i| {
        if (!l.live) continue;
        place(i, @intCast(l.x), @intCast(l.y)); // re-clamp into new scene
    }
}

// ---- focus / raise -------------------------------------------------------------

fn focusWindow(handle: i32) void {
    for (layers[0..], 0..) |*l, i| {
        if (l.kind == .window) l.win.focused = (@as(i32, @intCast(i)) == handle);
    }
}

fn raiseLayer(handle: i32) void {
    if (handle < 0 or @as(usize, @intCast(handle)) >= MAX_LAYERS) return;
    const l = &layers[@intCast(handle)];
    if (!l.live) return;
    l.z = z_next;
    z_next += 1;
    // z decides pixels — raising changes pxIn resolution across the
    // layer's whole rect (overlaps now resolve to THIS layer). Without
    // damage the composite keeps stale pixels until an unrelated move
    // repaints: click-to-raise looked dead until you dragged (T590 r6).
    _ = damage(l.x, l.y, l.w, l.h);
}

// topmost window layer containing scene point (x,y) — hit-test walks
// z-desc, so the raised window always wins.
fn topmostWindowAt(x: i32, y: i32) i32 {
    var best_z: u32 = 0;
    var best: i32 = -1;
    for (layers[0..], 0..) |*l, i| {
        if (!l.live or l.kind != .window) continue;
        if (l.z <= best_z) continue;
        if (x < @as(i32, @intCast(l.x)) or y < @as(i32, @intCast(l.y))) continue;
        if (x >= @as(i32, @intCast(l.x + l.w)) or y >= @as(i32, @intCast(l.y + l.h))) continue;
        best_z = l.z;
        best = @intCast(i);
    }
    return best;
}

pub fn isFocused(handle: i32) bool {
    if (handle < 0 or @as(usize, @intCast(handle)) >= MAX_LAYERS) return false;
    return layers[@intCast(handle)].win.focused;
}

// focused window handle, or -1 when root (console) holds keys.
pub fn focusedWindow() i32 {
    for (layers[0..], 0..) |*l, i| {
        if (l.live and l.kind == .window and l.win.focused) return @intCast(i);
    }
    return -1;
}

// topmost window regardless of focus — kwclose's fallback target.
pub fn topWindow() i32 {
    var best_z: u32 = 0;
    var best: i32 = -1;
    for (layers[0..], 0..) |*l, i| {
        if (!l.live or l.kind != .window) continue;
        if (l.z <= best_z) continue;
        best_z = l.z;
        best = @intCast(i);
    }
    return best;
}

// keyboard routing stub — returns the focused window ONLY if it
// declares key intake. v1: no window does, so this is always -1 and
// the shell keeps every key. The seam exists so MC-3 clients can
// declare intake without compositor rework.
pub fn keyTarget() i32 {
    const f = focusedWindow();
    if (f < 0) return -1;
    const l = &layers[@intCast(f)];
    return if (l.win.key_intake) f else -1;
}

// ---- per-tick input routing ------------------------------------------------------
// press EDGE (not level) hit-tests top-down: inside a window -> focus
// +raise; inside its titlebar -> also arm drag; outside all -> root
// focus. Drag = grab offset + move requests through place().

pub fn tick() void {
    if (!live) return;
    const held = ptr_buttons > 0;
    if (ptr_on and held and !ptr_prev_held) {
        const hit = topmostWindowAt(ptr_x, ptr_y);
        if (hit >= 0) {
            focusWindow(hit);
            raiseLayer(hit);
            const l = &layers[@intCast(hit)];
            const in_title = (ptr_y - @as(i32, @intCast(l.y))) >= 0 and
                (ptr_y - @as(i32, @intCast(l.y))) < @as(i32, @intCast(l.win.title_h));
            if (in_title) {
                l.win.dragging = true;
                drag_handle = hit;
                l.win.grab_dx = ptr_x - @as(i32, @intCast(l.x));
                l.win.grab_dy = ptr_y - @as(i32, @intCast(l.y));
                say("comp: drag arm\n");
            } else {
                say("comp: focus window\n");
            }
        } else {
            // outside all windows -> root focus (console keeps keys)
            for (layers[0..]) |*l| {
                if (l.kind == .window) l.win.focused = false;
            }
            say("comp: focus root\n");
        }
    }
    ptr_prev_held = held;
    if (drag_handle >= 0) {
        if (!ptr_on or !held) {
            if (drag_handle >= 0 and @as(usize, @intCast(drag_handle)) < MAX_LAYERS)
                layers[@intCast(drag_handle)].win.dragging = false;
            drag_handle = -1;
            say("comp: drag drop\n");
        } else {
            const l = &layers[@intCast(drag_handle)];
            place(@intCast(drag_handle),
                @as(i64, ptr_x) - @as(i64, l.win.grab_dx),
                @as(i64, ptr_y) - @as(i64, l.win.grab_dy));
        }
    }
}

// ---- GPU composite seam (gpublt.zig) ------------------------------------------
// The scene core stays the authority on z/damage semantics; the GPU blit
// backend reads layers through this read-only view and emits copies in
// z-asc painter's order (opaque XRGB8888 == pxIn topmost-wins).

pub const LayerView = struct {
    buf: [*]u32,
    pitch: u32, // pixels per row
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    z: u32,
    kind: Kind,
};

pub fn layerSlots() usize {
    return MAX_LAYERS;
}

// live layer at slot i, or null — slot order is NOT z order; callers
// sort by .z themselves.
pub fn layerView(i: usize) ?LayerView {
    if (i >= MAX_LAYERS) return null;
    const l = &layers[i];
    if (!l.live) return null;
    return .{
        .buf = l.buf,
        .pitch = l.pitch,
        .x = l.x,
        .y = l.y,
        .w = l.w,
        .h = l.h,
        .z = l.z,
        .kind = l.kind,
    };
}

// ---- producer-side queries (MC-3) ---------------------------------------------
// win.zig's ui windows need pointer pos + their own scene origin for
// CmdView hit-testing — comp owns both, so it hands them out read-only.

pub fn pointerPos(x: *i32, y: *i32, on: *bool, buttons: *u32) void {
    x.* = ptr_x;
    y.* = ptr_y;
    on.* = ptr_on;
    buttons.* = ptr_buttons;
}

pub fn scenePos(handle: i32, x: *u32, y: *u32) bool {
    if (handle < 0 or @as(usize, @intCast(handle)) >= MAX_LAYERS) return false;
    const l = &layers[@intCast(handle)];
    if (!l.live) return false;
    x.* = l.x;
    y.* = l.y;
    return true;
}

// ---- init ---------------------------------------------------------------------

pub fn init() void {
    var info: Info = undefined;
    if (koruos_fb_info(&info) == 0) return;
    W = info.width;
    H = info.height;
    @memset(&layers, .{});
    z_next = 1;
    pending.clear();
    drag_handle = -1;
    ptr_prev_held = false;
    cur_handle = -1;
    live = true;
    say("comp: scene live ");
    koru_putdec(W);
    say("x");
    koru_putdec(H);
    say(" layers=");
    koru_putdec(MAX_LAYERS);
    say(" dmg=");
    koru_putdec(MAX_DMG);
    say("\n");
}

// ---- fullBoot/surf.zig compat ---------------------------------------------------
// The immediate-mode flush the dead fullBoot path used: drain pending
// into whatever linear scanout fb names. Live path uses present.zig.
pub fn flush() void {
    const d = takePending();
    if (d.empty()) return;
    var s: ScanoutInfo = undefined;
    if (koruos_fb_scanout(&s) == 0) {
        say("comp: flush — no linear scanout, damage dropped (named)\n");
        return;
    }
    const t = Target{
        .px = @ptrFromInt(@as(usize, @intCast(s.phys))),
        .pitch = s.pitch / 4,
        .w = s.w,
        .h = s.h,
    };
    compositeAcc(&t, &d);
}
