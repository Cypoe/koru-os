// koru/native pci — config-space enumeration over CF8/CFC type-1 cycles.
//
// The scan runs ONCE, early in kmain: providers look their hardware up in
// the Device table — they never rescan the bus and never open-code config
// cycles (fb.zig and virtio.zig both did before this module existed; the
// duplication was the tell that enumeration is a substrate, not a probe).
//
// Coverage, honest: multifunction devices via header-type bit 7, PCI-PCI
// bridges recursed by secondary bus number (visited bitmap — a looped
// bridge topology cannot recurse forever), 64-bit BARs merged, capability
// lists walkable via capFind (MSI/MSI-X/virtio-pci vendors live there).
// ECAM/MMCONFIG is not needed on type-1-only hardware; an MCFG arm is a
// separate provider when one lands.

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
fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
        : .{ .memory = true });
}
fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
        : .{ .memory = true });
}

fn cfgAddr(bus: u8, slot: u8, func: u8, off: u8) u32 {
    return 0x80000000 | (@as(u32, bus) << 16) | (@as(u32, slot & 0x1F) << 11) |
        (@as(u32, func & 7) << 8) | (off & 0xFC);
}

// CFC..CFF are byte-addressable: a width-accurate access keeps the
// address dword aligned and offsets the DATA port. A byte read at off%4==3
// goes to port 0xCFF, not a shifted 32-bit read — devices may gate
// individual byte enables.
pub fn read8(bus: u8, slot: u8, func: u8, off: u8) u8 {
    outl(0xCF8, cfgAddr(bus, slot, func, off));
    return inb(0xCFC + @as(u16, off & 3));
}
pub fn read16(bus: u8, slot: u8, func: u8, off: u8) u16 {
    outl(0xCF8, cfgAddr(bus, slot, func, off));
    return inw(0xCFC + @as(u16, off & 2));
}
pub fn read32(bus: u8, slot: u8, func: u8, off: u8) u32 {
    outl(0xCF8, cfgAddr(bus, slot, func, off));
    return inl(0xCFC);
}
pub fn write8(bus: u8, slot: u8, func: u8, off: u8, v: u8) void {
    outl(0xCF8, cfgAddr(bus, slot, func, off));
    outb(0xCFC + @as(u16, off & 3), v);
}
pub fn write16(bus: u8, slot: u8, func: u8, off: u8, v: u16) void {
    outl(0xCF8, cfgAddr(bus, slot, func, off));
    outw(0xCFC + @as(u16, off & 2), v);
}
pub fn write32(bus: u8, slot: u8, func: u8, off: u8, v: u32) void {
    outl(0xCF8, cfgAddr(bus, slot, func, off));
    outl(0xCFC, v);
}

// ---- the device table: the enumeration's product ------------------------

pub const Device = struct {
    bus: u8,
    slot: u8,
    func: u8,
    vendor: u16,
    device: u16,
    class: u8,
    subclass: u8,
    progif: u8,
    hdr: u8, // header type, low 7 bits
    cap: u8, // capability-list head offset, 0 = none
    irq_line: u8,
    irq_pin: u8,
    bars: [6]u32, // raw; a 64-bit BAR's high dword rides the next slot
};

pub var devices: [64]Device = undefined;
pub var count: u32 = 0;

var seen_bus: [8]u32 = .{0} ** 8; // 256-bit visited bitmap — bridge loops bounded

fn record(bus: u8, slot: u8, func: u8) ?*Device {
    const id = read32(bus, slot, func, 0x00);
    if (id == 0xFFFFFFFF) return null;
    if (count == devices.len) return null; // full table: the count line says so
    const d = &devices[count];
    const cls = read32(bus, slot, func, 0x08);
    const status = read32(bus, slot, func, 0x04) >> 16;
    const intr = read32(bus, slot, func, 0x3C);
    d.* = .{
        .bus = bus,
        .slot = slot,
        .func = func,
        .vendor = @intCast(id & 0xFFFF),
        .device = @intCast(id >> 16),
        .class = @intCast(cls >> 24),
        .subclass = @intCast((cls >> 16) & 0xFF),
        .progif = @intCast((cls >> 8) & 0xFF),
        .hdr = read8(bus, slot, func, 0x0E) & 0x7F,
        .cap = if ((status & 0x10) != 0) read8(bus, slot, func, 0x34) & 0xFC else 0,
        .irq_line = @intCast(intr & 0xFF),
        .irq_pin = @intCast((intr >> 8) & 0xFF),
        .bars = .{0} ** 6,
    };
    // BAR count is header-shaped: type 0 has six, bridges two, cardbus one.
    const nbars: usize = switch (d.hdr) {
        0 => 6,
        1 => 2,
        else => 0,
    };
    var i: usize = 0;
    while (i < nbars) : (i += 1) {
        const b = read32(bus, slot, func, @intCast(0x10 + 4 * i));
        d.bars[i] = b;
        if ((b & 1) == 0 and (b & 6) == 4 and i + 1 < nbars) {
            d.bars[i + 1] = read32(bus, slot, func, @intCast(0x10 + 4 * (i + 1)));
            i += 1; // 64-bit BAR consumed two slots
        }
    }
    count += 1;
    return d;
}

fn scanBus(bus: u8) void {
    if (seen_bus[bus >> 5] & (@as(u32, 1) << @intCast(bus & 31)) != 0) return;
    seen_bus[bus >> 5] |= @as(u32, 1) << @intCast(bus & 31);
    var slot: u8 = 0;
    while (slot < 32) : (slot += 1) {
        if (read16(bus, slot, 0, 0) == 0xFFFF) continue;
        const multifn = (read8(bus, slot, 0, 0x0E) & 0x80) != 0;
        const nfuncs: u8 = if (multifn) 8 else 1;
        var func: u8 = 0;
        while (func < nfuncs) : (func += 1) {
            const d = record(bus, slot, func) orelse continue;
            if (d.class == 0x06 and d.subclass == 0x04) {
                // PCI-PCI bridge: the secondary bus at 0x19 is this
                // device's downstream — enumerate it.
                scanBus(read8(bus, slot, func, 0x19));
            }
        }
    }
}

// ---- lookup + capabilities ----------------------------------------------

pub fn find(vendor: u16, device: u16) ?*const Device {
    for (devices[0..count]) |*d|
        if (d.vendor == vendor and d.device == device) return d;
    return null;
}

pub fn findClass(class: u8, subclass: u8) ?*const Device {
    for (devices[0..count]) |*d|
        if (d.class == class and d.subclass == subclass) return d;
    return null;
}

// capFind: walk the capability list (status bit 4 → head at 0x34, each cap
// is {id@0, next@1}); returns the cap's config offset or 0. MSI is 0x05,
// MSI-X 0x11, virtio-pci vendor 0x09 — the walk is what MSI-X and modern
// virtio negotiation will consume when their providers land.
pub fn capFind(d: *const Device, id: u8) u8 {
    var off = d.cap;
    var hops: u8 = 0;
    while (off != 0 and hops < 48) : (hops += 1) {
        if (read8(d.bus, d.slot, d.func, off) == id) return off;
        off = read8(d.bus, d.slot, d.func, off + 1) & 0xFC;
    }
    return 0;
}

// command register: the bits providers actually flip — I/O space (0),
// memory space (1), bus master (2), INTx disable (10).
pub fn command(d: *const Device) u16 {
    return read16(d.bus, d.slot, d.func, 0x04);
}
pub fn setCommand(d: *const Device, v: u16) void {
    write16(d.bus, d.slot, d.func, 0x04, v);
}

// ---- init + the serial dump that is the enumeration's evidence ----------

extern fn koru_say(s: [*:0]const u8) void;

fn hexw(v: u64, comptime w: usize) void {
    var buf: [w + 1]u8 = undefined;
    buf[w] = 0;
    var i: usize = 0;
    while (i < w) : (i += 1) {
        const nib = (v >> @intCast(4 * (w - 1 - i))) & 0xF;
        buf[i] = "0123456789abcdef"[@intCast(nib)];
    }
    koru_say(@ptrCast(&buf));
}
fn say(s: [*:0]const u8) void {
    koru_say(s);
}

fn dump(d: *const Device) void {
    say("pci: ");
    hexw(d.bus, 2);
    say(":");
    hexw(d.slot, 2);
    say(".");
    hexw(d.func, 1);
    say(" ");
    hexw(d.vendor, 4);
    say(":");
    hexw(d.device, 4);
    say(" class=");
    hexw(d.class, 2);
    say("/");
    hexw(d.subclass, 2);
    say("/");
    hexw(d.progif, 2);
    say(" irq=");
    hexw(d.irq_line, 2);
    // the cap-list walk doubles as capFind's oracle — printed so the gate
    // can see what negotiation material each device carries
    var off = d.cap;
    var hops: u8 = 0;
    say(" caps=");
    if (off == 0) say("-");
    while (off != 0 and hops < 48) : (hops += 1) {
        if (hops > 0) say(",");
        hexw(read8(d.bus, d.slot, d.func, off), 2);
        off = read8(d.bus, d.slot, d.func, off + 1) & 0xFC;
    }
    say("\n");
}

pub fn init() void {
    scanBus(0);
    for (devices[0..count]) |*d| dump(d);
    say("pci: ");
    hexw(count, 2);
    say(" devices enumerated\n");
}

const std = @import("std");
