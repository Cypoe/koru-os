// koru/native aspace — the first MMU capability family on native-runtime:
// per-domain page-table roots (CR3) that give each domain its own view of
// the same virtual address. This is the primitive the spawn rung-2
// provider (separate address spaces, ELF children) will stand on — it is
// NOT a spawn binding; rung 0/1 stays as declared.
//
// selftest() is the honest evidence path until a lift consumes it: clone
// the boot space, map the same 2 MiB window to different physical pages
// per space, switch CR3, and prove on serial that the VA resolves
// differently per domain.
//
// Layout (boot space): pml4[0] -> pdpt[0] -> pd[0..n] identity-maps all
// managed RAM (pmm.init fills it). The proof window lives at pd[257] ->
// VA 0x20200000 — above the identity ceiling under -m 64M, out of the way
// of children's pd[4] user window. Proof pages and space-B tables come
// from pmm.alloc — the selftest now *exercises* the allocator it used to
// bypass, and frees what it took.

extern var pml4: [512]u64;
extern var pdpt: [512]u64;
extern var pd: [512]u64;

const pmm = @import("pmm");

extern var stdout: ?*anyopaque;
extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;

const ENT: u64 = 0x3; // present | writable
const PS: u64 = 0x80; // 2 MiB page

const WIN_IDX: usize = 257;
const WIN_VA: usize = WIN_IDX * 0x200000; // 0x40400000

var b_pml4: u64 = 0;
var b_pdpt: u64 = 0;
var b_pd: u64 = 0;
var a_phys: u64 = 0;
var b_phys: u64 = 0;
var built = false;

fn say(s: [*:0]const u8) void {
    _ = fputs(s, stdout);
}

fn allocTable() ?u64 {
    const phys = pmm.alloc() orelse return null;
    const t: *align(4096) [512]u64 = @ptrFromInt(@as(usize, @intCast(phys)));
    @memset(t, 0);
    return phys;
}

fn loadCr3(pml4_phys: usize) void {
    asm volatile ("mov %[p], %%cr3"
        :
        : [p] "r" (pml4_phys),
        : .{ .memory = true });
}

fn buildSpaceB() bool {
    b_pml4 = allocTable() orelse return false;
    b_pdpt = allocTable() orelse return false;
    b_pd = allocTable() orelse return false;
    const bpml4: *[512]u64 = @ptrFromInt(@as(usize, @intCast(b_pml4)));
    const bpdpt: *[512]u64 = @ptrFromInt(@as(usize, @intCast(b_pdpt)));
    const bpd: *[512]u64 = @ptrFromInt(@as(usize, @intCast(b_pd)));
    bpml4[0] = b_pdpt | ENT;
    bpdpt[0] = b_pd | ENT;
    bpd.* = pd; // share the kernel identity maps
    built = true;
    return true;
}

// Serial evidence: two CR3s, one VA, different physical content. The two
// backing frames come from the allocator and are freed on exit.
// Prints "ASPACE A=<hex> B=<hex> DISTINCT|SAME".
pub fn selftest() void {
    if (!built and !buildSpaceB()) {
        say("ASPACE FAIL: table alloc\n");
        return;
    }
    // 2 MiB-leaf window: the backing frames must be 2 MiB-aligned or the
    // PDE's low phys bits read as reserved and the walk #PFs.
    a_phys = pmm.alloc2M() orelse {
        say("ASPACE FAIL: frame alloc\n");
        return;
    };
    b_phys = pmm.alloc2M() orelse {
        say("ASPACE FAIL: frame alloc\n");
        return;
    };
    const win: *volatile u64 = @ptrFromInt(WIN_VA);
    const bpd: *[512]u64 = @ptrFromInt(@as(usize, @intCast(b_pd)));

    // space A claims the window -> phys A
    pd[WIN_IDX] = a_phys | PS | ENT;
    loadCr3(@intFromPtr(&pml4)); // flush stale not-present translation
    win.* = 0xAAAAAAAA_AAAAAAAA;

    // space B: same VA -> phys B
    bpd[WIN_IDX] = b_phys | PS | ENT;
    loadCr3(b_pml4);
    win.* = 0xBBBBBBBB_BBBBBBBB;
    const b_val = win.*;

    // back to A: the window must show A's bytes again
    loadCr3(@intFromPtr(&pml4));
    const a_val = win.*;

    // hand everything back: window entry, 2 MiB blocks, space-B tables
    pd[WIN_IDX] = 0;
    _ = pmm.freeBlock(a_phys, 512);
    _ = pmm.freeBlock(b_phys, 512);
    _ = pmm.free(b_pd);
    _ = pmm.free(b_pdpt);
    _ = pmm.free(b_pml4);
    built = false;

    if (a_val == 0xAAAAAAAA_AAAAAAAA and b_val == 0xBBBBBBBB_BBBBBBBB) {
        say("ASPACE A=aaaaaaaa B=bbbbbbbb DISTINCT\n");
    } else {
        say("ASPACE FAIL: window not isolated\n");
    }
}
