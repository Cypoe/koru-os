// koruos/native fb provider — the linear-framebuffer seam.
//
// Two honest sources, tried in order:
//   1. multiboot2 mbi tag 8 — the loader (GRUB) programmed a mode and tells
//      us the phys address + pitch + dims. boot.zig's header requests it.
//   2. BGA — QEMU's std VGA implements the Bochs VBE_DISPI port interface
//      (0x1CE/0x1CF); we program the mode ourselves and read the LFB phys
//      address from PCI BAR0. This is what QEMU -kernel gives us, since its
//      built-in multiboot loader does not honor the fb request tag.
//
// Either way the fb is identity-mapped into the boot page tables (pd[] is
// shared with _start's 2 MiB pages). Only bpp-32 direct color is served;
// anything else is absent — loud refusal, never a half-decoded pixel.
//
// Externs are the `koruos.fb` iface's koru-native mechanism: info/fill/px.

extern var pd: [512]u64; // boot.zig's 2 MiB-page table (identity map, GB 0)
extern var pdpt: [512]u64; // boot.zig's pdpt — pd covers GB 0; pd_hi covers GB 3
// One spare pd covers exactly one 1 GiB window above GB 0 — enough for the
// fb, which is a single contiguous range. A second window needs the frame
// allocator's page-table story; this is deliberately not it.
var pd_hi: [512]u64 align(4096) = [_]u64{0} ** 512;

var present: bool = false;
var fb_base: [*]volatile u32 = undefined;
var fb_width: u32 = 0;
var fb_height: u32 = 0;
var fb_pitch: u32 = 0; // bytes per scanline

// --- port I/O ----------------------------------------------------------

fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (port),
        : .{ .memory = true });
}
fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "{dx}" (port),
        : .{ .memory = true });
}
fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
        : .{ .memory = true });
}
fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "{dx}" (port),
        : .{ .memory = true });
}

// --- source 1: multiboot2 tag 8 ----------------------------------------

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

fn fromMbi(mbi_phys: u32) bool {
    if (mbi_phys == 0) return false;
    const base: [*]const u8 = @ptrFromInt(mbi_phys);
    const total = std.mem.readInt(u32, base[0..4], .little);
    var off: usize = 8;
    while (off + 8 <= total) {
        const t = std.mem.readInt(u32, base[off..][0..4], .little);
        const s = std.mem.readInt(u32, base[off + 4 ..][0..4], .little);
        if (t == 0) break;
        if (t == 8 and s >= @sizeOf(Mb2Fb)) {
            const f: *align(1) const Mb2Fb = @ptrCast(base + off);
            if (f.bpp == 32 and f.fb_type == 1) { // direct-color linear only
                adopt(f.addr, f.pitch, f.width, f.height);
                return true;
            }
            return false;
        }
        off += (s + 7) & ~@as(usize, 7); // tags are 8-byte aligned
    }
    return false;
}

// --- source 2: BGA (Bochs/QEMU std VGA) ---------------------------------

const BGA_INDEX: u16 = 0x1CE;
const BGA_DATA: u16 = 0x1CF;
const VBE_ID: u16 = 0xB0C5; // BGA version 5
const DISPI_ID: u16 = 0;
const DISPI_XRES: u16 = 1;
const DISPI_YRES: u16 = 2;
const DISPI_BPP: u16 = 3;
const DISPI_ENABLE: u16 = 4;
const DISPI_ON_LFB: u16 = 0x41; // ENABLED | LFB_ENABLED

fn bgaWrite(idx: u16, v: u16) void {
    outw(BGA_INDEX, idx);
    outw(BGA_DATA, v);
}
fn bgaRead(idx: u16) u16 {
    outw(BGA_INDEX, idx);
    return inw(BGA_DATA);
}

fn pciAddr(bus: u8, devno: u5, func: u3, off: u8) u32 {
    return @as(u32, 0x80000000) | (@as(u32, bus) << 16) | (@as(u32, devno) << 11) |
        (@as(u32, func) << 8) | (off & 0xFC);
}
fn pciRead32(bus: u8, devno: u5, func: u3, off: u8) u32 {
    outl(0xCF8, pciAddr(bus, devno, func, off));
    return inl(0xCFC);
}

// Scan for a display-class PCI device (class 0x03), return BAR0's phys base.
fn findDisplayBar() ?u64 {
    var bus: u32 = 0;
    while (bus < 256) : (bus += 1) {
        var dev: u32 = 0;
        while (dev < 32) : (dev += 1) {
            const id = pciRead32(@intCast(bus), @intCast(dev), 0, 0x00);
            if (id == 0xFFFFFFFF) continue;
            const class = pciRead32(@intCast(bus), @intCast(dev), 0, 0x08) >> 24;
            if (class != 0x03) continue;
            const bar0 = pciRead32(@intCast(bus), @intCast(dev), 0, 0x10);
            if ((bar0 & 1) != 0) return null; // I/O BAR — not our LFB shape
            const cmd = pciRead32(@intCast(bus), @intCast(dev), 0, 0x04);
            outl(0xCF8, pciAddr(@intCast(bus), @intCast(dev), 0, 0x04));
            outl(0xCFC, cmd | 0x6); // mem-space + bus-master enable
            return bar0 & ~@as(u32, 0xF);
        }
    }
    return null;
}

fn fromBga() bool {
    if (bgaRead(DISPI_ID) < VBE_ID) return false; // not a BGA
    const bar = findDisplayBar() orelse return false;
    const w: u16 = 1024;
    const h: u16 = 768;
    bgaWrite(DISPI_ENABLE, 0); // disable before mode set
    bgaWrite(DISPI_XRES, w);
    bgaWrite(DISPI_YRES, h);
    bgaWrite(DISPI_BPP, 32);
    bgaWrite(DISPI_ENABLE, DISPI_ON_LFB);
    adopt(bar, @as(u32, w) * 4, w, h);
    return true;
}

// --- shared adopt/map ----------------------------------------------------

fn adopt(phys: u64, pitch: u32, w: u32, h: u32) void {
    map(phys, @as(u64, pitch) * h);
    fb_base = @ptrFromInt(@as(usize, @intCast(phys))); // identity map
    fb_width = w;
    fb_height = h;
    fb_pitch = pitch;
    present = true;
}

// Identity-map [phys, phys+len) with 2 MiB pages in the boot pd. Entries are
// cache-disabled (PCD) — fb memory wants write-combining at minimum; honest
// uncached until PAT setup exists.
fn map(phys: u64, len: u64) void {
    const first = phys & ~@as(u64, 0x1FFFFF);
    const last = (phys + len + 0x1FFFFF) & ~@as(u64, 0x1FFFFF);
    var p = first;
    while (p < last) : (p += 0x200000) {
        const gb = p >> 30;
        // One pd covers one 1 GiB window; pdpt[gb] gets pd_hi on demand.
        const table: *[512]u64 = if (gb == 0) &pd else blk: {
            pdpt[gb] = @intFromPtr(&pd_hi) | 0x3;
            break :blk &pd_hi;
        };
        table[(p >> 21) & 0x1FF] = p | 0x93; // present | rw | PCD | 2MiB page
    }
    asm volatile ("mov %cr3, %rax\n\tmov %rax, %cr3"
        :
        :
        : .{ .rax = true, .memory = true });
}

// --- init + externs ------------------------------------------------------

pub fn init(mbi_phys: u32) void {
    if (fromMbi(mbi_phys)) return;
    _ = fromBga();
}

const Info = extern struct {
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
};

pub export fn koruos_fb_info(out: *Info) callconv(.c) u8 {
    if (!present) return 0;
    out.* = .{ .width = fb_width, .height = fb_height, .pitch = fb_pitch, .bpp = 32 };
    return 1;
}

pub export fn koruos_fb_px(x: u32, y: u32, color: u32) callconv(.c) u8 {
    if (!present or x >= fb_width or y >= fb_height) return 0;
    fb_base[y * (fb_pitch / 4) + x] = color;
    return 1;
}

pub export fn koruos_fb_fill(x: u32, y: u32, w: u32, h: u32, color: u32) callconv(.c) u8 {
    if (!present) return 0;
    const row = fb_pitch / 4;
    const x1 = @min(x + w, fb_width);
    const y1 = @min(y + h, fb_height);
    var yy = @min(y, fb_height);
    while (yy < y1) : (yy += 1) {
        var xx = @min(x, fb_width);
        while (xx < x1) : (xx += 1) fb_base[yy * row + xx] = color;
    }
    return 1;
}

const std = @import("std");
