// koru/native mmio — identity-map a physical window into the boot
// address space (device BARs, the fb LFB, the LAPIC page).
//
// One module owns this because the mechanism is a shared resource:
// the boot pd[] covers GB 0 only — anything above needs a hi pd
// installed into pdpt[gb], and there is exactly ONE spare table. Two
// modules each holding their own pd_hi and installing pdpt[3] would
// evict each other's mappings — the collision is silent and the
// symptom is a device write going nowhere. So the window lives here,
// and the second DISTINCT gigabyte window refuses loudly instead of
// corrupting the first.
//
// Entries are cache-disabled (PCD) — fb and MMIO want write-combining
// at minimum; honest uncached until PAT setup exists.

extern var pd: [512]u64; // boot.zig's 2 MiB-page table (identity map, GB 0)
extern var pdpt: [512]u64; // boot.zig's pdpt — pd covers GB 0

// The single hi window: pd_hi serves exactly one 1 GiB range above GB 0.
// A second window needs the frame allocator's page-table story; this is
// deliberately not it — the refusal names that bound.
var pd_hi: [512]u64 align(4096) = [_]u64{0} ** 512;
var pd_hi_gb: u32 = 0xFFFFFFFF; // which GB window pd_hi currently serves

extern fn koru_say(s: [*:0]const u8) void;

// map [phys, phys+len) with 2 MiB pages. Identity map — the returned VA
// IS the physical address. Returns false (loudly) if the range needs a
// second hi window.
pub fn map(phys: u64, len: u64) bool {
    const first = phys & ~@as(u64, 0x1FFFFF);
    const last = (phys + len + 0x1FFFFF) & ~@as(u64, 0x1FFFFF);
    var p = first;
    while (p < last) : (p += 0x200000) {
        const gb: u32 = @intCast(p >> 30);
        const table: *[512]u64 = if (gb == 0) &pd else blk: {
            if (pd_hi_gb == 0xFFFFFFFF) {
                pd_hi_gb = gb;
                pdpt[gb] = @intFromPtr(&pd_hi) | 0x3;
            } else if (pd_hi_gb != gb) {
                koru_say("mmio: second hi window refused — one spare pd\n");
                return false;
            }
            break :blk &pd_hi;
        };
        table[(p >> 21) & 0x1FF] = p | 0x93; // present | rw | PCD | 2MiB page
    }
    asm volatile ("mov %cr3, %rax\n\tmov %rax, %cr3"
        :
        :
        : .{ .rax = true, .memory = true });
    return true;
}
