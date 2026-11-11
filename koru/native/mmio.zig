// koru/native mmio — identity-map a physical window into the boot
// address space (device BARs, the fb LFB, the LAPIC page).
//
// One module owns this because the mechanism is a shared resource:
// the boot pd[] covers GB 0 only — anything above needs a hi pd
// installed into pdpt[gb]. Two modules each installing pdpt[gb] would
// evict each other's mappings — the collision is silent and the symptom
// is a device write going nowhere. So windows mint here and nowhere
// else: each distinct 1 GiB range gets its own pd, allocated on demand
// from pmm. (The pre-pmm design held exactly one spare table — the
// allocator landing dissolved the bound, not the single-owner rule.)
//
// Entries are cache-disabled (PCD) — fb and MMIO want write-combining
// at minimum; honest uncached until PAT setup exists.

const std = @import("std");

extern var pd: [512]u64; // boot.zig's 2 MiB-page table (identity map, GB 0)
extern var pdpt: [512]u64; // boot.zig's pdpt — pd covers GB 0

extern fn koru_say(s: [*:0]const u8) void;

fn say(s: [*:0]const u8) void {
    koru_say(s);
}

// Page directories for hi-GiB windows are PERMANENT kernel metadata —
// once installed in pdpt[gb] they live for the boot. They come from a
// static pool, not pmm.alloc: the frame allocator made every hi-GiB
// window hostage to memory-map bringup succeeding first, and on the
// T590's UEFI-booted GRUB path pmm found no mb2 mmap tag (managed=0,
// alloc()=null forever) — so the LAPIC and IO-APIC windows at GB3
// stayed unmapped and the box had no PCI interrupt door at all.
// Measured: vbirq8 lapic probe=0, ioapic initDirect refused.
const PD_POOL_N: usize = 16; // GB1..GB16 windows; APIC sits in GB3
var pdPool: [PD_POOL_N][512]u64 = undefined;
var pdUsed: [PD_POOL_N]bool = .{false} ** PD_POOL_N;

fn mintPd() ?* [512]u64 {
    for (&pdUsed, 0..) |*u, i| {
        if (!u.*) {
            u.* = true;
            return &pdPool[i];
        }
    }
    return null;
}

// map [phys, phys+len) with 2 MiB pages. Identity map — the returned VA
// IS the physical address. False only when the page-table budget runs
// out, and it says so — the window is never silently absent.
pub fn map(phys: u64, len: u64) bool {
    const first = phys & ~@as(u64, 0x1FFFFF);
    const last = (phys + len + 0x1FFFFF) & ~@as(u64, 0x1FFFFF);
    var p = first;
    while (p < last) : (p += 0x200000) {
        const gb: u32 = @intCast(p >> 30);
        var table: *[512]u64 = &pd;
        if (gb != 0) {
            if (gb >= 512) return false;
            if (pdpt[gb] == 0) {
                const t = mintPd() orelse {
                    say("mmio: pd pool exhausted — hi window refused\n");
                    return false;
                };
                @memset(t, 0);
                // VA==PA identity: the pool's link-time address IS the
                // physical address the pdpt entry needs.
                pdpt[gb] = @intFromPtr(t) | 0x3;
            }
            table = @ptrFromInt(pdpt[gb] & ~@as(u64, 0xFFF));
        }
        table[(p >> 21) & 0x1FF] = p | 0x93; // present | rw | PCD | 2MiB page
    }
    asm volatile ("mov %cr3, %rax\n\tmov %rax, %cr3"
        :
        :
        : .{ .rax = true, .memory = true });
    return true;
}
