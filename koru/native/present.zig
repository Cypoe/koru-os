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
const gpublt = @import("i915/gpublt.zig");
const net = @import("net");
const pmm = @import("pmm");
const mmio = @import("mmio");
const text = @import("text.zig");

extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern var stdout: ?*anyopaque;

const MAX_BUFS: usize = 2;
const MAX_FLIP_FAILS: u32 = 12;
// Vblank-oracle timeout: flip_pending normally clears on a DEIIR edge.
// If DEIIR never latches on this panel (unverified assumption — M2's
// vblankWait result was discarded, so a dead IIR was never caught),
// the swapchain froze after frame 1 on T590: prompt visible, then no
// echo/window ever. Timeout ticks bound the stall — the display
// engine applies each DSPASURF at vblank regardless, so a timed-out
// re-arm still produces live (if tear-prone) flips instead of a
// frozen frame.
const FLIP_TIMEOUT_TICKS: u64 = 2048; // ~16-60ms at shell-loop rates — the pacer while DEIIR is unproven
var flip_age: u64 = 0; // ticks since flip_pending armed
var timeout_clears: u64 = 0;
var last_vblank_raw: u32 = 0; // last DEIIR read — kstat oracle

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
var armed_frm: u32 = 0; // FRMCNT at arm time — delta = flip landed at a frame boundary
var vb_armed: bool = false;
var vb_emit_n: u64 = 0;   // ticks since last vb: telemetry line
var vb_last_flips: u64 = 0; // flip_count at last emit — +f delta = fps
var perf_last_flips: u64 = 0;
var perf_last_tsc: u64 = 0;
var paint_tsc: u64 = 0;   // cumulative rdtsc inside paintFrame
var paint_n: u64 = 0;     // paintFrame calls — avg = paint_tsc/paint_n
var paint_min: u64 = ~@as(u64, 0); // best-case paintFrame — separates compute from stall

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc" : [lo] "={eax}" (lo), [hi] "={edx}" (hi));
    return (@as(u64, hi) << 32) | lo;
}
var last_gen: u64 = 0;
var last_mode_was_flip: bool = false;
var retry_n: u64 = 0;
var retry_wait: u64 = 64; // ensureFlip backoff — grows x4 per failure
var flip_fails: u32 = 0;
var flip_gave_up: bool = false; // latched until next gen change
var flip_count: u64 = 0;
var gpu_frames: u64 = 0; // frames composited via BCS blits
var cpu_frames: u64 = 0; // frames CPU-composited (named fallback)
var paint_count: u64 = 0;
var pre_scanout: ?u32 = null; // foreign scanout to retire after first flip

// ---- console root backing ---------------------------------------------------
// Owned here (not shell.zig) so the gen-change path can resize it with
// the scene: a modeset to different dims leaves a W*H backing that can't
// cover the new scene — the T590 "console invisible post-kms" regression.
// The backing is pmm; text.zig's Sink points at it and reports damage.

const CON_BG: u32 = 0x001A1A2E;
var con_phys: u64 = 0;
var con_pages: usize = 0;
var con_handle: i32 = -1;
var con_buf: [*]volatile u32 = undefined;
var con_pitch: u32 = 0;
var con_w: u32 = 0;
var con_h: u32 = 0;
var console_reset: bool = false; // a realloc wiped console content — shell re-renders prompt

fn consoleAlloc(w: u32, h: u32) bool {
    const bytes = @as(u64, w) * h * 4;
    const pages: usize = @intCast((bytes + 4095) / 4096);
    const phys = pmm.allocContiguous(pages, 1) orelse return false;
    if (!mmio.map(phys, bytes)) {
        _ = pmm.freeBlock(phys, pages);
        return false;
    }
    const buf: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(phys)));
    var i: usize = 0;
    while (i < @as(usize, w) * h) : (i += 1) buf[i] = CON_BG;
    con_phys = phys;
    con_pages = pages;
    con_buf = buf;
    con_pitch = w;
    con_w = w;
    con_h = h;
    return true;
}

fn consoleFree() void {
    if (con_phys != 0) _ = pmm.freeBlock(con_phys, con_pages);
    con_phys = 0;
    con_pages = 0;
    con_buf = undefined;
    con_handle = -1;
}

fn consoleBind() void {
    text.setColor(0xFFFFFFFF, CON_BG);
    text.sink = .{
        .px = con_buf,
        .pitch = con_pitch,
        .w = con_w,
        .h = con_h,
        .damage = comp.sceneDamage,
    };
    con_handle = comp.attachRoot(@volatileCast(con_buf), con_pitch, con_w, con_h);
}

// consoleUp — allocate the full-scene console backing and attach it as
// comp's .root layer. Called once from shell.run after comp.init.
pub fn consoleUp() void {
    var w: u32 = 0;
    var h: u32 = 0;
    comp.dims(&w, &h);
    if (w == 0 or h == 0) {
        text.puts("scene: no dims — console stays on scanout\n");
        return;
    }
    if (!consoleAlloc(w, h)) {
        text.puts("scene: console backing alloc failed — scanout console\n");
        return;
    }
    consoleBind();
    text.puts("scene: console root layer ");
    text.putdec(w);
    text.putc('x');
    text.putdec(h);
    text.puts(if (con_handle >= 0) " up\n" else " REFUSED\n");
}

// consoleRealloc — detach the old root, free its backing, allocate and
// bind a new one at (w,h). Shared core of consoleSync/consoleForce.
fn consoleRealloc(w: u32, h: u32) bool {
    const old = con_handle;
    if (old >= 0) comp.detach(old);
    consoleFree();
    if (!consoleAlloc(w, h)) {
        text.sink = null; // loud: console falls back to direct scanout writes
        text.puts("scene: console backing alloc failed — scanout console\n");
        return false;
    }
    consoleBind();
    console_reset = true; // content wiped — caller decides how to repopulate
    return true;
}

// takeConsoleReset — shell polls once per loop iteration: true means the
// console backing was reallocated since last take (fresh blank console —
// re-print prompt + current input line). Consumed on read.
pub fn takeConsoleReset() bool {
    const r = console_reset;
    console_reset = false;
    return r;
}

// surfaceSync — the gen-change core WITHOUT the present-side teardown:
// scene dims + console backing catch up to a new scanout. Dispatch calls
// this right after a modeset/flip command returns so the "... returned"
// puts + prompt land in the NEW backing instead of the doomed one.
pub fn surfaceSync() void {
    comp.syncDims();
    consoleSync();
}

// consoleSync — the gen-change hook. Same dims -> the retained backing
// is still valid (console text SURVIVES a same-geometry modeset — that
// is the point of retention). Different dims -> realloc: old glyph
// pixels can't be remapped, so the console restarts fresh (named — the
// pre-MC1 modeset wiped the scanout anyway).
pub fn consoleSync() void {
    var w: u32 = 0;
    var h: u32 = 0;
    comp.dims(&w, &h);
    if (w == 0 or h == 0) return;
    if (con_handle < 0) {
        consoleUp(); // was never up (alloc failed at boot) — retry now
        return;
    }
    if (w == con_w and h == con_h) return;
    if (!consoleRealloc(w, h)) return;
    sayU("KORU scene: console resized {d}x{d} — fresh console\n", .{ w, h });
}

// consoleForce — diagnostic: rebind the root backing at ARBITRARY dims
// (QEMU can't modeset, so this is how the resize mechanics get verified
// without i915). Root layer smaller/larger than scene clips honestly.
pub fn consoleForce(w: u32, h: u32) void {
    if (w == 0 or h == 0) return;
    if (!consoleRealloc(w, h)) return;
    sayU("KORU scene: console forced {d}x{d}\n", .{ w, h });
}

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
    flip_age = 0;
    commit_armed = false;
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

// Deferred flip commit — replaces the waitFrameEdge spin that parked
// the shell loop for up to a full frame period (~30-50ms of dead input
// polling per flip, KNOWN-JANK a). Composite lands, commit arms, and
// the edge is caught on a later tick: DSPASURF writes within ~1 tick
// (~15-30us) of the FRMCNT edge — still inside vblank, zero blocking.
var commit_armed: bool = false;
var commit_handle: u32 = 0;
var commit_back: usize = 0;
var commit_frm: u32 = 0;
var commit_irq: u64 = 0; // vblankIrqCount at arm — IRQ-edge oracle (0-safe)
var armed_irq: u64 = 0;  // vblankIrqCount when flip_pending armed
var commit_age: u32 = 0;
var commit_rects: u32 = 0;
var commit_full: bool = false;
const COMMIT_TIMEOUT_TICKS: u32 = 4096; // ~3+ frames — dead-FRMCNT degrade

fn flipTick() void {
    // Periodic vblank telemetry on the automatic stream — T590 can't
    // run kstat mid-drag, so the candidate regs ride sparsely (1<<20
    // ticks ≈ every ~20-30s at shell rate — the vblank oracle hunt is
    // still open, but 1s cadence was pure overhead in the hot path).
    // Diff consecutive samples: whichever reg toggles at ~60Hz is the
    // real vblank oracle. +f = flips this interval = real fps.
    vb_emit_n += 1;
    if (vb_emit_n >= (1 << 20)) {
        vb_emit_n = 0;
        const vr = kms.vblankRegs();
        const df = flip_count - vb_last_flips;
        vb_last_flips = flip_count;
        sayU("vb DE={x} DI={x} SD={x} SI={x} I28={x} GT={x}\n",
            .{ vr[0], vr[1], vr[2], vr[3], vr[4], vr[5] });
        sayU("vb FR={x} PS={x} IM={x} IS={x} II={x} +f={d} pd={d} to={d}\n",
            .{ vr[6], vr[7], vr[8], vr[9], vr[10], df,
               @intFromBool(flip_pending), timeout_clears });
    }
    // perf — objective jank oracle on the panel (wire dies post-kms).
    // TSC wall-clock window: f= flips in window, t= tsc ticks elapsed
    // — fps = f / (t / tsc_hz). Drag ~10s, read several lines. High fps
    // + gpu climbing = render keeps up -> jank is input-side; low fps
    // = the flip/compositor path is the bottleneck.
    const tnow = rdtsc();
    if (tnow - perf_last_tsc >= 0x80000000) { // ~1-2s at ~2-4GHz TSC
        const df = flip_count - perf_last_flips;
        const dt = tnow - perf_last_tsc;
        perf_last_flips = flip_count;
        perf_last_tsc = tnow;
        text.puts("perf f="); text.putdec(df);
        text.puts(" t="); text.putdec(dt);
        text.puts(" to="); text.putdec(timeout_clears);
        text.puts(" pt="); text.putdec(if (paint_n == 0) 0 else paint_tsc / paint_n);
        text.puts(" pm="); text.putdec(paint_min);
        text.puts(" fw="); text.putdec(if (gpublt.fw_n == 0) 0 else gpublt.fw_tsc / gpublt.fw_n);
        text.puts(" fb="); text.putdec(gpublt.flush_bytes);
        text.puts(" ec="); text.putdec(gpublt.emit_count);
        text.puts(" bd="); text.putdec(if (gpublt.build_n == 0) 0 else gpublt.build_tsc / gpublt.build_n);
        text.puts(" pr="); text.putdec(if (gpublt.pre_n == 0) 0 else gpublt.pre_tsc / gpublt.pre_n);
        text.puts(" ac="); text.putdec(gpublt.arm_calls);
        text.puts(" ai="); text.putdec(gpublt.arm_inner_calls);
        text.puts(" iq="); text.putdec(if (paint_n == 0) 0 else gpublt.irq_during * 100 / paint_n);
        text.puts(" fe="); text.putdec(if (gpublt.fe_n == 0) 0 else gpublt.fe_tsc / gpublt.fe_n);
        text.puts(" sb="); text.putdec(if (gpublt.sb_n == 0) 0 else gpublt.sb_tsc / gpublt.sb_n);
        text.puts(" x1="); text.putdec(if (paint_n == 0) 0 else gpublt.px1 / paint_n);
        text.puts(" x2="); text.putdec(if (paint_n == 0) 0 else gpublt.px2 / paint_n);
        text.puts(" x3="); text.putdec(if (paint_n == 0) 0 else gpublt.px3 / paint_n);
        text.puts(" gpu="); text.putdec(gpu_frames);
        text.puts(" cpu="); text.putdec(cpu_frames); text.puts("\n");
    }
    // vblank oracle FIRST: any latched DE event means >=1 vblank passed
    // since the last drain — an armed flip has landed, the old front is
    // safe to paint again. Timeout fallback: if DEIIR never latches
    // (dead oracle — M2 never verified it), pending would stick after
    // frame 1 and the scene froze (T590 r3: prompt visible, no echo,
    // no window). Bounded stall -> live tear-prone flips instead.
    const ev = kms.vblankDrain();
    last_vblank_raw = ev;
    const frm = kms.frameCount();
    const irqc = kms.vblankIrqCount(); // 0 until vbirq arms MSI — safe oracle
    if (flip_pending) {
        // Clear on: real IIR event, OR FRMCNT advanced past armed_frm,
        // OR the vblank IRQ count advanced past armed_irq (interrupt-
        // driven edge — the T590 MSI path proves 1:1 with FRMCNT), OR
        // the bounded timeout if all oracles are dead.
        if (ev != 0 or frm != armed_frm or irqc != armed_irq) {
            flip_pending = false;
            flip_age = 0;
        } else {
            flip_age += 1;
            if (flip_age >= FLIP_TIMEOUT_TICKS) {
                flip_pending = false;
                flip_age = 0;
                timeout_clears += 1;
                if (timeout_clears == 1 or timeout_clears % 64 == 0)
                    sayU("KORU scene: vblank oracle silent — timeout clear {d}\n",
                        .{timeout_clears});
            }
        }
    }

    fanDamage(comp.takePending());

    // deferred commit — edge seen (or dead-counter timeout) => land
    // DSPASURF now; otherwise damage keeps accumulating in the accs.
    if (commit_armed) {
        commit_age += 1;
        if (kms.frameCount() != commit_frm or irqc != commit_irq or
            commit_age >= COMMIT_TIMEOUT_TICKS)
        {
            if (kms.flipSwapFast(commit_handle)) {
                armed_frm = kms.frameCount();
                armed_irq = kms.vblankIrqCount();
                if (front == null) {
                    if (pre_scanout) |m| {
                        if (m != commit_handle) _ = kms.dumbDestroy(m);
                    }
                    pre_scanout = null;
                }
                front = commit_back;
                flip_pending = true;
                flip_age = 0;
                flip_count += 1;
                if (flip_count == 1 or flip_count % 120 == 0)
                    sayU("KORU scene: flip {d} back={d} rects={d} full={d}\n",
                        .{ flip_count, commit_back, commit_rects,
                           @intFromBool(commit_full) });
            } else {
                sayU("KORU scene: flipSwap refused handle={d}\n",
                    .{commit_handle});
            }
            commit_armed = false;
        }
        return; // still waiting on the edge — nothing else to do
    }

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
    // GPU path first: damage rects -> BCS XY_SRC_COPY_BLT into the scene
    // dumb's GGTT mapping, fence-polled, then the cursor XOR pass.
    // paintFrame returns false on any named degrade (engine down, GTT
    // map refused, fence timeout) — the CPU composite below is the
    // explicit honest fallback, counted, never silent.
    const p0 = rdtsc();
    if (gpublt.paintFrame(b.handle, &b.acc)) {
        gpu_frames += 1;
    } else {
        comp.compositeAcc(&t, &b.acc);
        cpu_frames += 1;
    }
    const pd = rdtsc() - p0;
    paint_tsc += pd;
    paint_n += 1;
    if (pd < paint_min) paint_min = pd;
    const was_full = b.acc.full;
    const nr = b.acc.n;
    b.acc.clear();

    // Arm the deferred commit — the edge is caught on a later flipTick,
    // so the shell loop never stalls waiting for vblank (KNOWN-JANK a).
    commit_armed = true;
    commit_handle = b.handle;
    commit_back = back;
    commit_frm = kms.frameCount();
    commit_irq = kms.vblankIrqCount();
    commit_age = 0;
    commit_rects = @intCast(nr);
    commit_full = was_full;
}

pub fn init() void {
    last_gen = fb.generation();
    last_mode_was_flip = false;
}

// kstat — the flip-path oracle. Dumps swapchain state, the DEIIR raw
// last read, the plane's programmed DSPASURF, and READBACK PIXELS from
// each scene buffer's CPU map — proving whether composite wrote
// content into the buffer the display engine is pointed at.
pub fn stat() void {
    sayU("present: flips={d} pending={d} age={d} timeouts={d} vb_raw={x} fails={d} gaveup={d} gpu={d} cpu={d}\n",
        .{ flip_count, @intFromBool(flip_pending), flip_age, timeout_clears,
           last_vblank_raw, flip_fails, @intFromBool(flip_gave_up),
           gpu_frames, cpu_frames });
    gpublt.stat();
    var sx: i32 = 0;
    var sy: i32 = 0;
    var son: bool = false;
    var sbtn: u32 = 0;
    comp.pointerPos(&sx, &sy, &son, &sbtn);
    for (bufs, 0..) |b, i| {
        if (!b.ok) {
            sayU("  buf{d}: down\n", .{i});
            continue;
        }
        // readback: center + top-left pixels of the composited surface,
        // plus the cursor pixel — buf0/buf1 divergence here = the
        // sprite-flicker oracle (each buffer must agree on XOR state).
        const cx = @as(usize, b.h / 2) * b.pitch + @as(usize, b.w / 2);
        const tl = @as(usize, 8) * b.pitch + 8;
        const pc: u32 = b.map[cx];
        const pt: u32 = b.map[tl];
        var spx: u32 = 0;
        // sample the tail-bar centre (sprite row 10 is all-ones — a
        // guaranteed SET bit, so a live XOR must differ from scene BG)
        const gx = sx + 5;
        const gy = sy + 10;
        if (son and gx >= 0 and gy >= 0 and
            @as(u32, @intCast(gx)) < b.w and @as(u32, @intCast(gy)) < b.h)
            spx = b.map[@as(usize, @intCast(gy)) * b.pitch +
                @as(usize, @intCast(gx))];
        sayU("  buf{d}: h={d} acc.n={d} acc.full={d} px@center={x} px@8,8={x} spr@={x}\n",
            .{ i, b.handle, b.acc.n, @intFromBool(b.acc.full), pc, pt, spx });
    }
    sayU("  front={d} dspsurf={x} pre_scanout={d}\n",
        .{ front orelse 99, kms.surfaceOffset(), pre_scanout orelse 999 });
    // vblank candidate regs via kms.vblankRegs — sayU dual-writes
    // serial+UDP (the earlier mmio.say path never reached the wire).
    if (kms.device().up) {
        const vr = kms.vblankRegs();
        sayU("  vb DEISR={x} DEIIR={x} SDEISR={x} SDEIIR={x}\n",
            .{ vr[0], vr[1], vr[2], vr[3] });
        sayU("  vb IIR28={x} GTIIR={x} FRMCNT={x} PSTAT24={x}\n",
            .{ vr[4], vr[5], vr[6], vr[7] });
        sayU("  vb LGCIMR={x} LGCISR={x} LGCIIR={x}\n",
            .{ vr[8], vr[9], vr[10] });
    } else {
        sayU("  vb i915 down — no regs\n", .{});
    }
}

pub fn tick() void {
    const g = fb.generation();
    if (g != last_gen) {
        last_gen = g;
        surfaceSync(); // scene dims + console backing follow the new scanout
        var w: u32 = 0;
        var h: u32 = 0;
        comp.dims(&w, &h);
        _ = comp.damage(0, 0, w, h); // modeset/surface swap = whole damage
        teardown();
        flip_pending = false;
        commit_armed = false;
        front = null;
        pre_scanout = null;
        flip_fails = 0;
        retry_wait = 64;
        flip_gave_up = false; // new surface = fresh contiguous-alloc budget
        sayU("KORU scene: surface gen change — full damage, swapchain reset\n", .{});
    }

    const up = kms.device().up;
    if (up) {
        retry_n += 1;
        // ensureFlip -> dumbCreate -> pmm.allocContiguous(~2k frames) is
        // an O(managed*n) bitmap scan on FAILURE — seconds per call.
        // Retrying it every 64 ticks starved pollChar to death on T590
        // (console rendered via immediateTick, heartbeats limped,
        // keyboard dead). Back off x4 per fail and latch gave_up after
        // MAX_FLIP_FAILS — immediate mode stays the named degrade until
        // the next gen change resets the attempt budget.
        if (!flipReady() and !flip_gave_up and (retry_n & (retry_wait - 1)) == 0) {
            if (ensureFlip()) {
                flip_fails = 0;
                retry_wait = 64;
            } else {
                flip_fails += 1;
                retry_wait = @min(retry_wait * 4, 1 << 22);
                if (flip_fails == 1 or flip_fails % 8 == 0)
                    sayU("KORU scene: flip alloc fail {d} — immediate mode, retry in {d} ticks\n",
                        .{ flip_fails, retry_wait });
                if (flip_fails >= MAX_FLIP_FAILS) {
                    flip_gave_up = true;
                    sayU("KORU scene: flip alloc gave up after {d} — immediate mode until gen change\n",
                        .{flip_fails});
                }
            }
        }
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
