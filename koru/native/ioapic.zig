// koru/native ioapic — GSI routing: the second interrupt door's wiring.
//
// MADT named the parts (ioapic phys, GSI base, interrupt-source
// overrides); this file owns the redirection table. A line routed here
// is LAPIC-delivered: its EOI goes to the LAPIC, its mask bit lives in
// IOREDTBL, and the PIC's word on it is void. Routing is per-line
// state, not a global switch — koru_irq_unmask consults gsiFor() and
// takes the owning door, so a provider never knows which mechanism
// carried its IRQ.
//
// init() runs between pci.init() (the table is up; intlines are known)
// and user.init() (the first unmask — the PIT's — routes here and the
// PIC never arms a line at all). Every IOREDTBL entry starts masked;
// unmask is the same verb either way.

const std = @import("std");
const acpi = @import("acpi");
const mmio = @import("mmio");
const pci = @import("pci");

extern fn koru_say(s: [*:0]const u8) void;
fn say(s: [*:0]const u8) void {
    koru_say(s);
}
fn sayf(comptime fmt: []const u8, args: anytype) void {
    var buf: [192]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    koru_say(s.ptr);
}

var iobase: usize = 0;
var npins: u32 = 0;
var live = false;

// irq# -> gsi; -1 means the line has no route here (PIC's word stands).
var gsiForLine: [16]i32 = .{-1} ** 16;
var lapicLine: [16]bool = .{false} ** 16;

// The query face user.zig consults per unmask/EOI.
pub fn gsiFor(irq: u8) ?u32 {
    if (!live or irq >= 16 or gsiForLine[irq] < 0) return null;
    return @intCast(gsiForLine[irq]);
}
pub fn isLapic(irq: u8) bool {
    return live and irq < 16 and lapicLine[irq];
}

// IOREGSEL/IOWIN — indexed register pair.
fn ioRd(reg: u8) u32 {
    @as(*volatile u32, @ptrFromInt(iobase + 0x00)).* = reg;
    return @as(*volatile u32, @ptrFromInt(iobase + 0x10)).*;
}
fn ioWr(reg: u8, v: u32) void {
    @as(*volatile u32, @ptrFromInt(iobase + 0x00)).* = reg;
    @as(*volatile u32, @ptrFromInt(iobase + 0x10)).* = v;
}

// rteRead — the raw IOREDTBL pair for irq#'s GSI. Diagnostic face for
// probes that must see mask/trigger/polarity/vector/destination without
// changing them; setMasked stays the only writer.
pub const Rte = struct { gsi: u32, lo: u32, hi: u32 };
pub fn rteRead(irq: u8) ?Rte {
    const gsi = gsiFor(irq) orelse return null;
    return .{
        .gsi = gsi,
        .lo = ioRd(@intCast(0x10 + gsi * 2)),
        .hi = ioRd(@intCast(0x11 + gsi * 2)),
    };
}

// IOREDTBL[gsi]: the lo dword's mask bit is the unmask knob — same
// semantic as the PIC's IMR, different door.
pub fn setMasked(gsi: u32, masked: bool) void {
    if (!live or gsi >= npins) return;
    const lo = ioRd(@intCast(0x10 + gsi * 2));
    ioWr(@intCast(0x10 + gsi * 2),
        if (masked) lo | (1 << 16) else lo & ~@as(u32, 1 << 16));
    sayf("ioapic: pin{d} {s} (lo={x})\n", .{ gsi,
        if (masked) "masked" else "unmasked", ioRd(@intCast(0x10 + gsi * 2)) });
}

fn isoLookup(irq: u8) ?acpi.Iso {
    for (acpi.isoList[0..@min(acpi.isos, 32)]) |e| {
        if (e.src == irq) return e;
    }
    return null;
}

// Route irq# through the IOAPIC. GSI comes from the ISO table when the
// firmware declared a remap (IRQ0 lives at pin 2 on i440fx — assuming
// irq==gsi is how systems lose the timer). Polarity/trigger come from
// the ISO flags (0 = bus-conformant: ISA is edge/high, PCI INTx is
// level/low); absent an override, `pciLine` picks the PCI default.
fn route(irq: u8, pciLine: bool, bsp: u8) void {
    if (irq >= 16) return;
    var gsi: u32 = irq;
    var pol: u32 = 0; // 1 = active low
    var trig: u32 = 0; // 1 = level
    if (isoLookup(irq)) |e| {
        gsi = e.gsi;
        if (e.flags & 3 == 3) pol = 1;
        if ((e.flags >> 2) & 3 == 3) trig = 1;
    } else if (pciLine) {
        pol = 1;
        trig = 1;
    }
    if (gsi >= npins) {
        sayf("ioapic: irq{d} gsi{d} past pins — refused\n", .{ irq, gsi });
        return;
    }
    if (gsiForLine[irq] >= 0) return; // shared GSI — first router owns it
    // lo: vector | pol<<13 | trig<<15 | masked<<16. hi: dest apic id
    // (phys mode) in the top byte.
    const lo: u32 = (0x20 + @as(u32, irq)) | (pol << 13) | (trig << 15) | (1 << 16);
    ioWr(@intCast(0x10 + gsi * 2), lo);
    ioWr(@intCast(0x11 + gsi * 2), @as(u32, bsp) << 24);
    gsiForLine[irq] = @intCast(gsi);
    lapicLine[irq] = true;
    sayf("  irq{d} -> gsi{d} {s}\n", .{ irq, gsi,
        if (trig == 1) "level-low" else "edge-high" });
}

fn outb(port: u16, v: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (v),
          [p] "{dx}" (port),
        : .{ .memory = true });
}

pub fn init() void {
    if (acpi.nioapics == 0 or acpi.ioapicPhys == 0) {
        say("ioapic: none in MADT — PIC door stands\n");
        return;
    }
    _ = mmio.map(acpi.ioapicPhys, 0x1000);
    _ = mmio.map(acpi.lapicPhys, 0x1000); // bsp's id lives here too
    iobase = @intCast(acpi.ioapicPhys);
    npins = ((ioRd(1) >> 16) & 0xFF) + 1;
    sayf("ioapic: base={x} id={d} pins={d} gsi-base={d}\n", .{
        acpi.ioapicPhys, ioRd(0) >> 24, npins, acpi.ioapicGsiBase,
    });
    const bsp: u8 = @truncate(
        @as(*volatile u32, @ptrFromInt(@as(usize, @intCast(acpi.lapicPhys)) + 0x20)).* >> 24);

    // ISA lines the kernel claims, then every PCI device intline — a
    // line left PIC-routed is dead the moment the PIC mask drops.
    route(0, false, bsp); // PIT
    route(1, false, bsp); // 8042
    route(12, false, bsp); // PS/2 aux
    for (pci.devices[0..pci.count]) |d| {
        if (d.irq_pin != 0 and d.irq_line != 0 and d.irq_line != 0xFF)
            route(d.irq_line, true, bsp);
    }

    live = true;
    // The PIC door closes here: every line we answer is LAPIC's now,
    // and an unrouted stray cannot storm a dead controller.
    outb(0x21, 0xFF);
    outb(0xA1, 0xFF);
    say("ioapic: pic lines masked — lapic owns delivery\n");
}
