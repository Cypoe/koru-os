// koru/native pmm — the physical frame allocator, rung: heap stops being a
// bump that swallows page tables and child pages forever.
//
// Discovery is honest: multiboot2 tag 6 (memory map) is the only source —
// type-1 regions are usable, everything else stays reserved. There is no
// invented fallback; a loader that withholds the map gets a loud refusal
// and every alloc fails.
//
// Model: one u8 refcount per 4 KiB frame. alloc() takes count 0→1;
// pin() shares (count+1) — the surface contract's "two handles, one
// buffer"; free() decrements and only returns the frame at 0. Freeing an
// unowned frame refuses loudly — a double-free is a bug, never absorbed.
//
// Bounds, stated not hidden:
//   - managed RAM is capped at the identity window (1 GiB, pdpt[0]) —
//     frames above it exist but are unmappable until the HHDM/map-window
//     story lands.
//   - allocContiguous is a first-fit bitmap scan — no buddy coalescing;
//     fine at 4 KiB granularity for the sizes a surface/scanout needs.
//   - the bitmap is .bss inside the image (288 KiB for the 1 GiB cap) —
//     kernel metadata is not itself frame-managed.

extern var pd: [512]u64; // boot.zig's identity pd — we extend it
extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern var stdout: ?*anyopaque;
extern var _end: u8; // link.ld — first byte past the image

const std = @import("std");

const FRAME: u64 = 4096;
const LIMIT: u64 = 1 << 30; // pdpt[0] covers GB 0 only — 1 GiB cap
const MAXFRAMES: usize = LIMIT / FRAME; // 262144

var refs: [MAXFRAMES]u8 = undefined;
var managed: u64 = 0; // frames < LIMIT that are usable per the mmap
var live: u64 = 0; // currently allocated
var hint: usize = 0; // alloc scan cursor

fn say(s: [*:0]const u8) void {
    _ = fputs(s, stdout);
}

fn sayf(comptime f: []const u8, a: anytype) void {
    var b: [256]u8 = undefined;
    const s = std.fmt.bufPrintZ(&b, f ++ "\n", a) catch return;
    say(s.ptr);
}

// ---- memory-map discovery ------------------------------------------------
// Two honest boot protocols, detected by what EBX actually points at:
//
//   PVH (QEMU -kernel — the note in our header makes QEMU take this path):
//     head u32 is 0x336ec578 (XEN_HVM_START_MAGIC); hvm_start_info v1
//     carries memmap_paddr/memmap_entries -> an E820-style table whose
//     entries are {addr u64, size u64, type u32, reserved u32}, type 1 = RAM.
//
//   multiboot2 (GRUB): tag 6 in the mbi — same E820 semantics, versioned
//     entry size. Kept because a GRUB chainload is a stated target.
//
// Anything else refuses: no guessed e820 fallback, no invented 64 MiB.

const MmapEntry = extern struct {
    addr: u64,
    len: u64,
    type: u32,
    reserved: u32,
};

const XEN_MAGIC: u32 = 0x336EC578;
const TYPE_RAM: u32 = 1; // E820 "usable" under both protocols

fn forEachMmapEntry(mbi_phys: u32, ctx: anytype, comptime f: anytype) bool {
    if (mbi_phys == 0) return false;
    const base: [*]const u8 = @ptrFromInt(mbi_phys);

    if (std.mem.readInt(u32, base[0..4], .little) == XEN_MAGIC) {
        // hvm_start_info: memmap at +40 (v1) — version field must say so.
        const version = std.mem.readInt(u32, base[4..8], .little);
        if (version < 1) return false;
        const mm_addr = std.mem.readInt(u64, base[40..48], .little);
        const mm_count = std.mem.readInt(u64, base[48..56], .little);
        if (mm_addr == 0 or mm_count == 0 or mm_count > 1024) return false;
        var i: u64 = 0;
        while (i < mm_count) : (i += 1) {
            const e: *align(1) const MmapEntry = @ptrFromInt(@as(usize, @intCast(mm_addr + i * @sizeOf(MmapEntry))));
            f(ctx, e.*);
        }
        return true;
    }

    // multiboot2: u32 total_size, u32 reserved, then 8-aligned tags.
    const total = std.mem.readInt(u32, base[0..4], .little);
    var off: usize = 8;
    while (off + 8 <= total) {
        const t = std.mem.readInt(u32, base[off..][0..4], .little);
        const s = std.mem.readInt(u32, base[off + 4 ..][0..4], .little);
        if (t == 0) break;
        if (t == 6 and s >= 24) {
            const esz = std.mem.readInt(u32, base[off + 8 ..][0..4], .little);
            if (esz < @sizeOf(MmapEntry)) return false;
            var eoff = off + 16;
            while (eoff + esz <= off + s) : (eoff += esz) {
                const e: *align(1) const MmapEntry = @ptrCast(base + eoff);
                f(ctx, e.*);
            }
            return true;
        }
        off += (s + 7) & ~@as(usize, 7);
    }
    return false;
}

// ---- frame ops ----------------------------------------------------------

fn frameNo(phys: u64) u64 {
    return phys / FRAME;
}

fn reserve(phys: u64, len: u64) void {
    var p = phys & ~@as(u64, FRAME - 1);
    const end = (phys + len + FRAME - 1) & ~@as(u64, FRAME - 1);
    while (p < end) : (p += FRAME) {
        const i = frameNo(p);
        if (i < MAXFRAMES) {
            if (refs[i] == 0) live += 1; // count it as owned, never freed
            refs[i] = 255; // reserved saturates — reserve is not a refcount
        }
    }
}

pub fn alloc() ?u64 {
    // two passes: hint..managed, then 0..hint — the hint is a heuristic,
    // not a boundary; freed frames below it stay reachable or every
    // alloc/free cycle leaks frames silently.
    var i = hint;
    while (i < managed) : (i += 1) {
        if (refs[i] == 0) {
            refs[i] = 1;
            live += 1;
            hint = i;
            return @as(u64, i) * FRAME;
        }
    }
    i = 0;
    while (i < hint) : (i += 1) {
        if (refs[i] == 0) {
            refs[i] = 1;
            live += 1;
            hint = i;
            return @as(u64, i) * FRAME;
        }
    }
    return null;
}

// Physically-contiguous run — scanout/DMA backing. First fit, no
// coalescing; callers that need > a few MiB of contiguous are asking the
// wrong question for this allocator. `align_frames` (a power of two) pins
// the run's start to that granularity — a 2 MiB-leaf mapping needs its
// base 2 MiB-aligned or the PDE's low phys bits read as reserved.
pub fn allocContiguous(n: usize, align_frames: usize) ?u64 {
    if (n == 0) return null;
    const mask = if (align_frames > 1) align_frames - 1 else 0;
    var i: usize = 0;
    while (i + n <= managed) {
        i = (i + mask) & ~mask;
        if (i + n > managed) return null;
        var ok = true;
        for (0..n) |k| {
            if (refs[i + k] != 0) {
                ok = false;
                break;
            }
        }
        if (ok) {
            for (i..i + n) |j| {
                refs[j] = 1;
                live += 1;
            }
            return @as(u64, i) * FRAME;
        }
        i += 1;
    }
    return null;
}

// A 2 MiB-aligned 2 MiB block — one large-page leaf.
pub fn alloc2M() ?u64 {
    return allocContiguous(512, 512);
}

// Drop one hold on each frame of a block returned by allocContiguous —
// the pair-release half of the surface contract.
pub fn freeBlock(phys: u64, n: usize) usize {
    var freed: usize = 0;
    for (0..n) |k| {
        if (free(phys + @as(u64, k) * FRAME)) freed += 1;
    }
    return freed;
}

// pin: another handle on a live frame (shared surface buffer, table page
// referenced by two spaces). Refuses on free/reserved frames.
pub fn pin(phys: u64) bool {
    const i = frameNo(phys);
    if (i >= managed) return false;
    if (refs[i] == 0 or refs[i] == 255) return false;
    if (refs[i] == 254) return false; // saturating — 254 sharers is absurd
    refs[i] += 1;
    return true;
}

// free: drop one hold. Returns false on a double-free / unowned frame —
// loud, the caller bugged. Reserved (255) frames refuse: you cannot free
// the kernel.
pub fn free(phys: u64) bool {
    const i = frameNo(phys);
    if (i >= managed or refs[i] == 0 or refs[i] == 255) {
        sayf("pmm: free refused phys={x} (unowned)", .{phys});
        return false;
    }
    refs[i] -= 1;
    if (refs[i] == 0) {
        live -= 1;
        if (i < hint) hint = i;
    }
    return true;
}

pub fn heldCount(phys: u64) u8 {
    const i = frameNo(phys);
    if (i >= managed) return 0;
    return refs[i];
}

// ---- init + identity map ------------------------------------------------

const Probe = struct { usable_end: u64, usable_bytes: u64 };

fn probeCb(p: *Probe, e: MmapEntry) void {
    if (e.type != TYPE_RAM) return;
    const end = @min(e.addr + e.len, LIMIT);
    if (end > e.addr) {
        p.usable_bytes += end - e.addr;
        if (end > p.usable_end) p.usable_end = end;
    }
}

fn freeCb(_: void, e: MmapEntry) void {
    if (e.type != TYPE_RAM) return;
    var p = e.addr & ~@as(u64, FRAME - 1);
    if (p < e.addr) p += FRAME;
    const end = @min(e.addr + e.len, LIMIT) & ~@as(u64, FRAME - 1);
    while (p < end) : (p += FRAME) {
        const i = frameNo(p);
        if (i < MAXFRAMES and refs[i] == 255) refs[i] = 0; // usable wins
    }
}

pub fn init(mbi_phys: u32) void {
    @memset(&refs, 255); // reserved until a usable region says otherwise

    var probe = Probe{ .usable_end = 0, .usable_bytes = 0 };
    if (!forEachMmapEntry(mbi_phys, &probe, probeCb)) {
        sayf("pmm: REFUSED — no memory map (PVH or mb2 tag 6); mbi={x}", .{mbi_phys});
        return;
    }
    managed = frameNo(probe.usable_end);
    _ = forEachMmapEntry(mbi_phys, {}, freeCb);

    // Owned-before-us: the image itself, the loader's info block (+ the
    // PVH memmap table it points at), low memory.
    const kend = @intFromPtr(&_end);
    reserve(0, 0x100000);
    reserve(0x100000, kend - 0x100000);
    if (mbi_phys != 0) {
        const base: [*]const u8 = @ptrFromInt(mbi_phys);
        if (std.mem.readInt(u32, base[0..4], .little) == XEN_MAGIC) {
            reserve(mbi_phys, 64); // hvm_start_info
            const mm_addr = std.mem.readInt(u64, base[40..48], .little);
            const mm_count = std.mem.readInt(u64, base[48..56], .little);
            if (mm_addr != 0 and mm_count <= 1024)
                reserve(mm_addr, mm_count * @sizeOf(MmapEntry));
        } else {
            const total = std.mem.readInt(u32, base[0..4], .little);
            reserve(mbi_phys, total);
        }
    }

    // Extend the identity map: pd[0..ceil(limit/2MiB)) so kernel code can
    // reach any managed frame at VA==phys. _start already did 0-32 MiB;
    // pd_hi (fb's window) is GB≥1, disjoint. Frames past 32 MiB become
    // touchable here — user.zig copies them through identity VA.
    var v: u64 = 32 * 1024 * 1024;
    while (v < probe.usable_end and v < LIMIT) : (v += 0x200000) {
        pd[(v >> 21) & 0x1FF] = v | 0x83; // present | rw | 2MiB
    }
    asm volatile ("mov %cr3, %rax\n\tmov %rax, %cr3"
        :
        :
        : .{ .rax = true, .memory = true });

    sayf("pmm: usable={d}MiB managed={d} frames live={d}", .{
        probe.usable_bytes / (1024 * 1024), managed, live,
    });
    selftest();
}

// ---- selftest (serial evidence, like aspace's) --------------------------

fn selftest() void {
    const a = alloc() orelse {
        say("PMM FAIL: first alloc\n");
        return;
    };
    const b = alloc() orelse {
        say("PMM FAIL: second alloc\n");
        return;
    };
    // pin shares a; a free drops one hold and the frame must stay live
    if (!pin(a)) {
        say("PMM FAIL: pin refused a live frame\n");
        return;
    }
    if (!free(a) or heldCount(a) != 1) {
        say("PMM FAIL: shared free did not leave one hold\n");
        return;
    }
    if (!free(a) or heldCount(a) != 0) {
        say("PMM FAIL: last free did not release\n");
        return;
    }
    if (free(a)) {
        say("PMM FAIL: double-free accepted\n");
        return;
    }
    if (!free(b)) {
        say("PMM FAIL: b release\n");
        return;
    }
    // the phys page must be real memory: write/read through identity
    const c = alloc() orelse {
        say("PMM FAIL: re-alloc\n");
        return;
    };
    const cw: *volatile u64 = @ptrFromInt(@as(usize, @intCast(c)));
    cw.* = 0xDEADBEEF_CAFEF00D;
    const ok = cw.* == 0xDEADBEEF_CAFEF00D;
    _ = free(c);
    if (!ok) {
        say("PMM FAIL: frame not writable through identity\n");
        return;
    }
    say("PMM selftest ok\n");
}
