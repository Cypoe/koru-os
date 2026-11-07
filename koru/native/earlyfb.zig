// koru/native/earlyfb — pre-console framebuffer boot oracle.
//
// The T590 has no serial adapter and the caps LED never responds (the
// 8042 LED path is dead on this EC), so the ONLY observability that
// works before net.init brings UDP up is the panel itself: GRUB hands
// the kernel a linear framebuffer via multiboot2 tag 8 and keeps
// scanning it until i915 modesets. This module adopts that fb at the
// top of kmain — before faults.install/pmm/net — using STATIC page
// tables (pmm and mmio.map don't exist yet), then drives text.zig so
// every boot stage renders as a line on the panel.
//
// Outcome table for a flash:
//   GRUB menu persists, no KORU text .... kernel never ran (bad flash/boot)
//   frozen "STAGE n" + "!! EXCEPTION" ... ran, faulted at stage n (IDT live)
//   last "STAGE n" stays, no more ....... ran, hung at stage n
//   stages reach S3 + UDP markers ....... boot healthy to shell
//
// fb.init later re-adopts the SAME lfb through mmio.map — the epd[]
// tables installed here are reused (pdpt[gb] already nonzero), so the
// early text and the console share one surface with no conflict.

const std = @import("std");
const fb = @import("fb.zig");
const text = @import("text.zig");

extern var pdpt: [512]u64; // boot.zig — pd covers GB0 only
extern var pd: [512]u64;
extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;

// One 4 KiB pd per 1 GiB window, for hi windows pmm can't serve yet.
// .bss is loader-zeroed; untouched entries stay not-present. 8 windows
// = 0..8 GiB — the GRUB LFB lands ~0xFD000000 (GB3) on QEMU and in
// similar high stolen-memory on real HW.
var epd: [8][512]u64 align(4096) = [_][512]u64{[_]u64{0} ** 512} ** 8;

const Mb2Fb = extern struct {
    type: u32,
    size: u32,
    addr: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
    fb_type: u8,
    reserved: u16,
};

var live: bool = false;

// Walk mbi tags for the framebuffer info tag (8); returns a copy.
fn probe(mbi_phys: u32) ?Mb2Fb {
    if (mbi_phys == 0) return null;
    const base: [*]const u8 = @ptrFromInt(mbi_phys);
    const total = std.mem.readInt(u32, base[0..4], .little);
    var off: usize = 8;
    while (off + 8 <= total) {
        const t = std.mem.readInt(u32, base[off..][0..4], .little);
        const s = std.mem.readInt(u32, base[off + 4 ..][0..4], .little);
        if (t == 0) break;
        if (t == 8 and s >= @sizeOf(Mb2Fb)) {
            const f: *align(1) const Mb2Fb = @ptrCast(base + off);
            return f.*;
        }
        off += (s + 7) & ~@as(usize, 7); // tags are 8-byte aligned
    }
    return null;
}

// Identity-map [phys,phys+len) with 2 MiB pages, using the static epd[]
// tables for hi GBs. Mirrors mmio.map's entry format minus PCD —
// cached is fine for a brief boot log, and fb.init re-maps PCD later.
fn mapWindow(phys: u64, len: u64) bool {
    const first = phys & ~@as(u64, 0x1FFFFF);
    const last = (phys + len + 0x1FFFFF) & ~@as(u64, 0x1FFFFF);
    var p = first;
    while (p < last) : (p += 0x200000) {
        const gb: usize = @intCast(p >> 30);
        if (gb >= epd.len) return false;
        var table: *[512]u64 = &pd;
        if (gb != 0) {
            if (pdpt[gb] == 0) {
                const taddr: u64 = @intCast(@intFromPtr(&epd[gb]));
                pdpt[gb] = (taddr & ~@as(u64, 0xFFF)) | 0x3;
            }
            table = @ptrFromInt(pdpt[gb] & ~@as(u64, 0xFFF));
        }
        table[(p >> 21) & 0x1FF] = p | 0x83; // P|RW|PS — 2 MiB, cached
    }
    // New mappings have no stale TLB entries, but reload CR3 anyway to
    // match mmio.map's discipline and flush anything speculative.
    asm volatile ("mov %cr3, %rax\n\tmov %rax, %cr3"
        :
        :
        : .{ .rax = true, .memory = true });
    return true;
}

// Adopt the loader's fb and draw the boot banner. Returns void; on any
// refusal the oracle stays blind and boot continues exactly as before.
pub fn init(mbi_phys: u32) void {
    const f = probe(mbi_phys) orelse {
        koru_say("efb: no mb2 tag8 — oracle blind\n");
        return;
    };
    if (f.bpp != 32 or f.fb_type != 1 or f.addr == 0
        or f.width == 0 or f.height == 0
        or f.width > 8192 or f.height > 8192) {
        koru_say("efb: tag8 unsupported — oracle blind\n");
        return;
    }
    const bytes = @as(u64, f.pitch) * @as(u64, f.height);
    if (!mapWindow(f.addr, bytes)) {
        koru_say("efb: mapWindow refused — oracle blind\n");
        return;
    }
    fb.adoptRaw(f.addr, f.pitch, f.width, f.height);
    text.init(); // clears the GRUB frame, cursor home — panel = our log
    live = true;
    koru_say("efb: live addr="); koru_putdec(f.addr);
    koru_say(" pitch="); koru_putdec(f.pitch);
    koru_say(" w="); koru_putdec(f.width);
    koru_say(" h="); koru_putdec(f.height); koru_say("\n");
    text.puts("== KORU M1 early-fb oracle ==");
    text.newline();
    stage(0, "kernel-ran");
}

// Append one stage line to the on-panel boot log; n is the milestone
// index, name a short tag. Also echoes to serial for anyone attached.
pub fn stage(n: u32, name: [*:0]const u8) void {
    if (!live) return;
    text.puts("STAGE ");
    text.putdec(n);
    text.puts(" ");
    text.puts(name);
    text.newline();
    koru_say("efb:S"); koru_putdec(n); koru_say(" "); koru_say(name); koru_say("\n");
}
