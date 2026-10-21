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
// Layout (boot space): pml4[0] -> pdpt[0] -> pd[0..2] identity-maps
// 0-6 MiB. The proof window uses the free pd[4] slot -> VA 0x800000.
// Target physical pages (0xA00000 / 0xC00000) are plain RAM inside
// QEMU -m 64M and outside the identity window — nothing else owns them.

extern var pml4: [512]u64;
extern var pdpt: [512]u64;
extern var pd: [512]u64;

extern var stdout: ?*anyopaque;
extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern fn posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) callconv(.c) c_int;

const ENT: u64 = 0x3; // present | writable
const PS: u64 = 0x80; // 2 MiB page

const WIN_VA: usize = 0x800000; // pd[4]
const A_PHYS: u64 = 0xA00000;
const B_PHYS: u64 = 0xC00000;

var b_pml4: *align(4096) [512]u64 = undefined;
var b_pdpt: *align(4096) [512]u64 = undefined;
var b_pd: *align(4096) [512]u64 = undefined;
var built = false;

fn say(s: [*:0]const u8) void {
    _ = fputs(s, stdout);
}

fn allocTable() ?*align(4096) [512]u64 {
    var p: ?*anyopaque = null;
    if (posix_memalign(&p, 4096, 4096) != 0 or p == null) return null;
    const t: *align(4096) [512]u64 = @ptrCast(@alignCast(p.?));
    @memset(t, 0);
    return t;
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
    b_pml4[0] = @intFromPtr(b_pdpt) | ENT;
    b_pdpt[0] = @intFromPtr(b_pd) | ENT;
    b_pd.* = pd; // share kernel+heap identity maps
    b_pd[4] = B_PHYS | PS | ENT;
    built = true;
    return true;
}

// Serial evidence: two CR3s, one VA, different physical content.
// Prints "ASPACE A=<hex> B=<hex> DISTINCT|SAME".
pub fn selftest() void {
    if (!built and !buildSpaceB()) {
        say("ASPACE FAIL: table alloc\n");
        return;
    }
    const win: *volatile u64 = @ptrFromInt(WIN_VA);

    // space A claims the window -> phys A
    pd[4] = A_PHYS | PS | ENT;
    loadCr3(@intFromPtr(&pml4)); // flush stale not-present translation
    win.* = 0xAAAAAAAA_AAAAAAAA;

    // space B: same VA -> phys B
    loadCr3(@intFromPtr(b_pml4));
    win.* = 0xBBBBBBBB_BBBBBBBB;
    const b_val = win.*;

    // back to A: the window must show A's bytes again
    loadCr3(@intFromPtr(&pml4));
    const a_val = win.*;

    if (a_val == 0xAAAAAAAA_AAAAAAAA and b_val == 0xBBBBBBBB_BBBBBBBB) {
        say("ASPACE A=aaaaaaaa B=bbbbbbbb DISTINCT\n");
    } else {
        say("ASPACE FAIL: window not isolated\n");
    }
}
