// koruos/native surface provider — koruos/surface over the fb seam,
// composited through comp.zig.
//
// A surface is what the hosted arms already agreed it is: a provider-
// owned pixel buffer + a commit point + a pair-release lifetime. The
// compositor owns the scene: open() maps the surface at the compositor's
// anchor on top of the z-stack, close() removes it and the vacated rect
// repaints from retained backings. Placement is still provider policy
// (a fixed anchor — there is no move verb yet); what changed is that
// stacking is real — z decides pixels, never present order.
//
// fill/px write the backing — never the display. present(damage) hands
// the clipped scene rect to the compositor, which walks the stack and
// commits through fb:present. A zero-area present refuses — commit
// means damage. A pointer that isn't a live pool slot refuses — the
// token is a handle, not an address to trust.

const comp = @import("comp");
const fb = @import("fb.zig");
const pmm = @import("pmm");

extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;

const MAX_SURF = 8;

const Surf = struct {
    live: bool = false,
    slot: i32 = -1, // compositor layer — index order is z
    x: u32 = 0, // scene placement — the compositor's, like a WM's
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
    var s: ?*Surf = null;
    for (&pool) |*c| {
        if (!c.live) {
            s = c;
            break;
        }
    }
    const slot_s = s orelse return null; // pool full — refuse by capacity
    const phys = pmm.allocContiguous(pages, 1) orelse return null;
    const buf: [*]u32 = @ptrFromInt(@as(usize, @intCast(phys)));
    @memset(buf[0 .. w * h], 0); // cleared before attach — map paints it
    var sx: u32 = 0;
    var sy: u32 = 0;
    const slot = comp.attach(buf, w, h, &sx, &sy);
    if (slot < 0) {
        _ = pmm.freeBlock(phys, pages);
        return null;
    }
    slot_s.* = .{
        .live = true,
        .slot = slot,
        .x = sx,
        .y = sy,
        .w = w,
        .h = h,
        .buf = buf,
        .phys = phys,
        .pages = pages,
    };
    opened += 1;
    koru_say("surf: open ");
    koru_putdec(w);
    koru_say("x");
    koru_putdec(h);
    koru_say(" at ");
    koru_putdec(slot_s.x);
    koru_say(",");
    koru_putdec(slot_s.y);
    koru_say("\n");
    return slot_s;
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
    if (x >= x1 or y >= y1) return 0;
    // damage is surface-local; the compositor works in scene coords and
    // decides pixels by z — presenting under a higher surface cannot
    // clobber it.
    return comp.damage(s.x + x, s.y + y, x1 - x, y1 - y);
}

pub export fn koruos_surface_close(p: ?*anyopaque) callconv(.c) u8 {
    const s = asSurf(p) orelse return 0;
    // detach before freeing — the reveal repaint reads lower backings
    // only, but the vacated rect must leave the stack first.
    comp.detach(@intCast(s.slot));
    _ = pmm.freeBlock(s.phys, s.pages);
    s.live = false;
    closed += 1;
    return 1;
}
