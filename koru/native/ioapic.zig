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
var bspId: u8 = 0;

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

// Probe face: raw routing-table state for wire dumps (vbirq5 asked why
// irq11 had no route — the answer lives in these three).
pub fn isLive() bool {
    return live;
}
pub fn pinCount() u32 {
    return npins;
}
pub const LineRoute = struct { gsi: i32, lapic: bool };
pub fn lineRoute(irq: u8) LineRoute {
    if (irq >= 16) return .{ .gsi = -1, .lapic = false };
    return .{ .gsi = gsiForLine[irq], .lapic = lapicLine[irq] };
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

// forceRoute — probe escape hatch: write irq#'s RTE at an explicit GSI
// with PCI INTx defaults (level/low, fixed delivery, vec 0x20+irq, dest
// BSP phys mode), bypassing the ISO lookup that refused the line at
// init. Starts masked; the caller unmasks via the normal path once the
// device chain is armed. Refuses a line already routed to a DIFFERENT
// gsi — two pins claiming one irq would double-deliver.
pub fn forceRoute(irq: u8, gsi: u32) bool {
    if (!live or irq >= 16 or gsi >= npins) return false;
    if (gsiForLine[irq] >= 0 and gsiForLine[irq] != @as(i32, @intCast(gsi)))
        return false;
    const lo: u32 = (0x20 + @as(u32, irq)) | (1 << 13) | (1 << 15) | (1 << 16);
    ioWr(@intCast(0x10 + gsi * 2), lo);
    ioWr(@intCast(0x11 + gsi * 2), @as(u32, bspId) << 24);
    gsiForLine[irq] = @intCast(gsi);
    lapicLine[irq] = true;
    return true;
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
fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "{dx}" (port),
        : .{ .memory = true });
}

// initDirect — MADT-less bringup. T590 measured: no RSDP reachable via
// mb2 tags / EBDA / BIOS window -> no MADT -> this init early-returned
// -> every line PIC-routed, and level-held PCI INTx can never make the
// edge the 8259 needs (vbirq4/5: master pending set, irq_hits=0). The
// PCH's IO-APIC lives at the fixed window 0xFEC00000 — probe it
// directly, validate VER's pin count before claiming, and route
// NOTHING: callers forceRoute the lines they need. ISA lines already
// working on the PIC keep their door until deliberately migrated.
// Probe-face state — initDirect validates the window and records what
// it found WITHOUT going live. vbirq9 armed both APICs at once and the
// wire died after kms; this isolates whether the IO-APIC's live state
// (vs the LAPIC's) is the killer before either is trusted.
pub var probeOk = false;
pub var probeId: u32 = 0;
pub var probeVer: u32 = 0;
pub var probePins: u32 = 0;

pub fn initDirect() bool {
    if (live) return true;
    if (acpi.ioapicPhys != 0) return false; // MADT path owns it
    _ = mmio.map(0xFEC00000, 0x1000);
    _ = mmio.map(0xFEE00000, 0x1000); // bsp's lapic id lives here
    iobase = 0xFEC00000;
    const id = ioRd(0);
    const ver = ioRd(1);
    const pins = ((ver >> 16) & 0xFF) + 1;
    if (ver == 0 or ver == 0xFFFF_FFFF or pins < 16 or pins > 64) {
        sayf("ioapic: direct @{x} implausible id={x} ver={x} — refused\n", .{
            iobase, id, ver,
        });
        iobase = 0;
        return false;
    }
    // Record the finding; deliberately NOT live, NOT masked, NOT
    // routed — the vbirq9 wire-death fork decides which APIC is safe
    // to arm before either goes live for real.
    probeOk = true;
    probeId = id;
    probeVer = ver;
    probePins = pins;
    sayf("ioapic: direct @{x} id={x} ver={x} pins={d} — probe only, not live\n", .{
        iobase, id, ver, pins,
    });
    iobase = 0; // leave the window unmapped-state clean for now
    return true;
}

// picMask — keep the legacy door shut on a line the IO-APIC now owns;
// without it a level INTx can double-deliver through both doors.
pub fn picMask(irq: u8) void {
    if (irq >= 16) return;
    const port: u16 = if (irq < 8) 0x21 else 0xA1;
    const bit: u3 = @intCast(irq & 7);
    outb(port, inb(port) | (@as(u8, 1) << bit));
}

pub fn init() void {
    if (acpi.nioapics == 0 or acpi.ioapicPhys == 0) {
        say("ioapic: none in MADT — PIC door stands\n");
        _ = initDirect(); // T590 path: probe the PCH window anyway
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
    bspId = bsp;

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
