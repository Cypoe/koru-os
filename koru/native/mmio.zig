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

const pmm = @import("pmm");

extern var pd: [512]u64; // boot.zig's 2 MiB-page table (identity map, GB 0)
extern var pdpt: [512]u64; // boot.zig's pdpt — pd covers GB 0

extern fn koru_say(s: [*:0]const u8) void;

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
                const f = pmm.alloc() orelse {
                    koru_say("mmio: hi window refused — no frame for pd\n");
                    return false;
                };
                const t: *[512]u64 = @ptrFromInt(f);
                @memset(t, 0);
                pdpt[gb] = f | 0x3;
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
