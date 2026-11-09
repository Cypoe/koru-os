// koru/native/present — the present seam: drains comp's damage
// accumulator and composites into the live scanout target.
//
// Two backends, chosen by device state — named, never silent:
//   A immediate: composite damage rects straight into fb.scanout()
//     (GRUB/EFI LFB pre-'kms', i915 dumb post-'kms'-pre-flip). Tear risk
//     on the scanned surface — named per design §3.3 MC-a.
//   B flip: two scene dumb buffers + per-buffer damage accumulators
//     (wlroots wlr_damage_ring reduced to 2). Every scene damage unions
//     into BOTH accs; each is cleared only when its buffer is painted.
//     flipSwap arms the flip; DEIIR polling gates the next composite —
//     the scanned buffer is never written, the armed buffer is never
//     re-written before its vblank lands.
//
// Surface identity: fb.generation() bumps on modeset/rebase (not on
// routine flips — rebaseQuiet). A gen change = whole-scene damage +
// swapchain teardown/re-ensure.

const std = @import("std");
const comp = @import("comp");
const fb = @import("fb.zig");
const kms = @import("i915/kms.zig");
const net = @import("net");

extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern var stdout: ?*anyopaque;

const MAX_BUFS: usize = 2;

const Buf = struct {
    ok: bool = false,
    handle: u32 = 0,
    map: [*]volatile u32 = undefined,
    pitch: u32 = 0, // pixels per row
    w: u32 = 0,
    h: u32 = 0,
    acc: comp.Acc = .{},
};

var bufs: [MAX_BUFS]Buf = .{ .{}, .{} };
var front: ?usize = null; // index of last flipSwapped buffer
var flip_pending: bool = false; // a flip is armed, vblank not yet seen
var vb_armed: bool = false;
var last_gen: u64 = 0;
var last_mode_was_flip: bool = false;
var retry_n: u64 = 0;
var flip_count: u64 = 0;
var paint_count: u64 = 0;
var pre_scanout: ?u32 = null; // foreign scanout to retire after first flip

fn sayU(comptime fmt: []const u8, args: anytype) void {
    var b: [224]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    b[s.len] = 0;
    _ = fputs(@ptrCast(&b), stdout);
    net.mirror(s);
}

fn flipReady() bool {
    return bufs[0].ok and bufs[1].ok;
}

fn teardown() void {
    for (&bufs) |*b| {
        if (b.ok) {
            _ = kms.dumbDestroy(b.handle); // refused if it's the scanout — named leak, never silent
            b.ok = false;
            b.acc.clear();
        }
    }
    front = null;
    flip_pending = false;
    pre_scanout = null;
}

// ensure the two scene dumbs exist, sized to the current scanout.
// Allocated lazily on first kms-up tick — pmm first-fit wants these
// ~16.6MB contiguous runs early, before window backings fragment RAM.
fn ensureFlip() bool {
    if (flipReady()) return true;
    const s = fb.scanout() orelse return false;
    if (s.w == 0 or s.h == 0) return false;
    var all_ok = true;
    for (&bufs, 0..) |*b, i| {
        if (b.ok) continue;
        const h = kms.dumbCreate(s.w, s.h, 32) orelse {
            all_ok = false;
            continue;
        };
        const db = kms.dumbGet(h) orelse {
            _ = kms.dumbDestroy(h);
            all_ok = false;
            continue;
        };
        if (db.map) |m| {
            b.* = .{
                .ok = true,
                .handle = h,
                .map = m,
                .pitch = db.pitch / 4,
                .w = db.width,
                .h = db.height,
                .acc = .{},
            };
            b.acc.full = true; // first paint covers the whole scene
        } else {
            _ = kms.dumbDestroy(h);
            all_ok = false;
        }
        _ = i;
    }
    if (!all_ok or !flipReady()) return false;
    if (!vb_armed) {
        kms.vblankArm(); // DEIIR unmasked — flip pacing has its oracle
        vb_armed = true;
    }
    pre_scanout = kms.device().scanout; // modeset/test buffer to retire post-first-flip
    sayU("KORU scene: flip buffers up {d}x{d} (2x dumb swapchain)\n", .{ s.w, s.h });
    return true;
}

// fan pending scene damage into both per-buffer accumulators.
fn fanDamage(p: comp.Acc) void {
    if (p.full) {
        bufs[0].acc.full = true;
        bufs[1].acc.full = true;
        return;
    }
    for (p.rects[0..p.n]) |r| {
        bufs[0].acc.add(r, compW(), compH());
        bufs[1].acc.add(r, compW(), compH());
    }
}

fn compW() u32 {
    var w: u32 = 0;
    var h: u32 = 0;
    comp.dims(&w, &h);
    return w;
}
fn compH() u32 {
    var w: u32 = 0;
    var h: u32 = 0;
    comp.dims(&w, &h);
    return h;
}

fn immediateTick() void {
    const p = comp.takePending();
    if (p.empty()) return;
    const s = fb.scanout() orelse {
        sayU("KORU scene: paint dropped — no linear scanout (named)\n", .{});
        return;
    };
    const t = comp.Target{
        .px = @ptrFromInt(@as(usize, @intCast(s.phys))),
        .pitch = s.pitch / 4,
        .w = s.w,
        .h = s.h,
    };
    comp.compositeAcc(&t, &p);
    paint_count += 1;
    if (paint_count == 1 or paint_count % 256 == 0)
        sayU("KORU scene: paint n={d} full={d} on {d}x{d}\n",
            .{ p.n, @intFromBool(p.full), s.w, s.h });
}

fn flipTick() void {
    // vblank oracle FIRST: any latched DE event means >=1 vblank passed
    // since the last drain — an armed flip has landed, the old front is
    // safe to paint again.
    const ev = kms.vblankDrain();
    if (flip_pending and ev != 0) flip_pending = false;

    fanDamage(comp.takePending());

    if (flip_pending) return; // armed buffer still in flight — damage waits in accs

    const back: usize = if (front) |f| 1 - f else 0;
    const b = &bufs[back];
    if (b.acc.empty()) return;

    // liveness: a diagnostic command (kflip/kdmabuf) may have destroyed
    // a scene buffer — detect, name, and let ensureFlip rebuild.
    if (kms.dumbGet(b.handle) == null) {
        sayU("KORU scene: flip buffer {d} lost — rebuilding swapchain\n", .{b.handle});
        teardown();
        return;
    }

    const t = comp.Target{ .px = b.map, .pitch = b.pitch, .w = b.w, .h = b.h };
    comp.compositeAcc(&t, &b.acc);
    const was_full = b.acc.full;
    const nr = b.acc.n;
    b.acc.clear();

    if (!kms.flipSwap(b.handle)) {
        sayU("KORU scene: flipSwap refused handle={d}\n", .{b.handle});
        return; // acc already cleared — buffer content is correct for next flip
    }
    if (front == null) {
        if (pre_scanout) |m| {
            if (m != b.handle) _ = kms.dumbDestroy(m); // retire modeset/test buffer
        }
        pre_scanout = null;
    }
    front = back;
    flip_pending = true;
    flip_count += 1;
    if (flip_count == 1 or flip_count % 120 == 0)
        sayU("KORU scene: flip {d} back={d} rects={d} full={d}\n",
            .{ flip_count, back, nr, @intFromBool(was_full) });
}

pub fn init() void {
    last_gen = fb.generation();
    last_mode_was_flip = false;
}

pub fn tick() void {
    const g = fb.generation();
    if (g != last_gen) {
        last_gen = g;
        var w: u32 = 0;
        var h: u32 = 0;
        comp.dims(&w, &h);
        _ = comp.damage(0, 0, w, h); // modeset/surface swap = whole damage
        teardown();
        flip_pending = false;
        front = null;
        pre_scanout = null;
        sayU("KORU scene: surface gen change — full damage, swapchain reset\n", .{});
    }

    const up = kms.device().up;
    if (up) {
        retry_n += 1;
        if (!flipReady() and (retry_n & 63) == 0) _ = ensureFlip();
        if (flipReady()) {
            flipTick();
            last_mode_was_flip = true;
            return;
        }
        if (last_mode_was_flip) {
            sayU("KORU scene: flip buffers lost — immediate mode (named)\n", .{});
            last_mode_was_flip = false;
        }
    }
    immediateTick();
}
