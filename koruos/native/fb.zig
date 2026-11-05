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

const pci = @import("pci");
const mmio = @import("mmio");
const vgpu = @import("gpu.zig");

// The seam is one framebuffer; the provider is whichever display device
// enumeration found. Backend dispatch: mb2 tag (loader-programmed) →
// virtio-gpu (a real driver) → BGA (std VGA's VBE_DISPI hack). LFB
// sources share `fb_base`; the gpu keeps its own backing + present.
const Backend = enum { none, lfb, vgpu };
var backend: Backend = .none;

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
                if (adopt(f.addr, f.pitch, f.width, f.height)) return true;
                koru_say("fb: mb2 mode set but LFB unmappable — refused\n");
                return false;
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

// The display device comes out of pci.zig's enumerated table (class 0x03,
// VGA-compatible subclass 0x00) — fb programs the mode, the substrate
// owns config space.
fn findDisplayBar() ?u64 {
    const d = pci.findClass(0x03, 0x00) orelse return null;
    const bar0 = d.bars[0];
    if ((bar0 & 1) != 0) return null; // I/O BAR — not our LFB shape
    pci.setCommand(d, pci.command(d) | 0x6); // mem-space + bus-master
    return bar0 & ~@as(u32, 0xF);
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
    if (!adopt(bar, @as(u32, w) * 4, w, h)) {
        koru_say("fb: bga mode set but LFB unmappable — refused\n");
        return false;
    }
    return true;
}

// --- shared adopt --------------------------------------------------------

// Returns false when the LFB's phys can't be mapped — the caller must
// not claim the backend: a mode tag that names memory we cannot reach
// is a refusal, not a framebuffer.
fn adopt(phys: u64, pitch: u32, w: u32, h: u32) bool {
    if (!mmio.map(phys, @as(u64, pitch) * h)) return false;
    fb_base = @ptrFromInt(@as(usize, @intCast(phys))); // identity map
    fb_width = w;
    fb_height = h;
    fb_pitch = pitch;
    present = true;
    backend = .lfb;
    return true;
}

// --- init + externs ------------------------------------------------------

pub fn init(mbi_phys: u32) void {
    if (fromMbi(mbi_phys)) {
        koru_say("fb: backend=mb2\n");
        return;
    }
    if (vgpu.init()) {
        backend = .vgpu;
        present = true;
        koru_say("fb: backend=vgpu\n");
        return;
    }
    if (fromBga()) koru_say("fb: backend=bga\n");
}

extern fn koru_say(s: [*:0]const u8) void;

pub const Info = extern struct {
    width: u32,
    height: u32,
    pitch: u32,
    bpp: u32,
};

pub export fn koruos_fb_info(out: *Info) callconv(.c) u8 {
    if (backend == .vgpu) return vgpu.fbInfo(out);
    if (!present) return 0;
    out.* = .{ .width = fb_width, .height = fb_height, .pitch = fb_pitch, .bpp = 32 };
    return 1;
}

pub export fn koruos_fb_px(x: u32, y: u32, color: u32) callconv(.c) u8 {
    if (backend == .vgpu) return vgpu.fbPx(x, y, color);
    if (!present or x >= fb_width or y >= fb_height) return 0;
    fb_base[y * (fb_pitch / 4) + x] = color;
    return 1;
}

pub export fn koruos_fb_fill(x: u32, y: u32, w: u32, h: u32, color: u32) callconv(.c) u8 {
    if (backend == .vgpu) return vgpu.fbFill(x, y, w, h, color);
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

// present is the commit verb: an LFB is scanned out continuously so its
// present is trivially satisfied — the device never needed the pixels
// handed over. A gpu surface commits only when asked: TRANSFER + FLUSH.
pub export fn koruos_fb_present(x: u32, y: u32, w: u32, h: u32) callconv(.c) u8 {
    if (backend == .vgpu) return vgpu.fbPresent(x, y, w, h);
    return if (present) 1 else 0;
}

const std = @import("std");
