// koru/native virtiopci — the MODERN virtio-pci transport.
//
// Legacy virtio (virtio.zig) lives behind a fixed I/O-port window and a
// transitional device id; modern devices (1af4:104x+) have none of that —
// the register windows are *named by vendor capabilities* (PCI cap 0x09):
// each cfg_type locates a (bar, offset, length) slice — common config,
// the notify doorbell, the ISR, the device config. Discovering them is
// enumeration work, so this module rides pci.zig's table and capNext;
// it does not rescan the bus.
//
// Scope, honest: split virtqueues at fully-programmable addresses
// (queue_desc/queue_avail/queue_device — no PFN constraint), feature
// negotiation with the FEATURES_OK handshake, MSI-X armed by the caller
// through pci.zig's helpers. Packed rings are a different layout — a
// separate shape when a device demands it.

const pci = @import("pci");
const mmio = @import("mmio");

extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;

// vendor-cap cfg_type values (cap 0x09, +3)
const CFG_COMMON: u8 = 1;
const CFG_NOTIFY: u8 = 2;
const CFG_ISR: u8 = 3;
const CFG_DEVICE: u8 = 4;
const CFG_PCICFG: u8 = 5; // alternate config access — not needed

// modern common-cfg register offsets
const CC_DEV_FEATURE_SEL: usize = 0x00; // u32
const CC_DEV_FEATURE: usize = 0x04; // u32
const CC_DRV_FEATURE_SEL: usize = 0x08; // u32
const CC_DRV_FEATURE: usize = 0x0C; // u32
const CC_MSIX_CONFIG: usize = 0x10; // u16
const CC_NUM_QUEUES: usize = 0x12; // u16
const CC_STATUS: usize = 0x14; // u8
const CC_CONFIG_GEN: usize = 0x15; // u8
const CC_QUEUE_SEL: usize = 0x16; // u16
const CC_QUEUE_SIZE: usize = 0x18; // u16
const CC_QUEUE_MSIX: usize = 0x1A; // u16
const CC_QUEUE_ENABLE: usize = 0x1C; // u16
const CC_QUEUE_NOFF: usize = 0x1E; // u16
const CC_QUEUE_DESC: usize = 0x20; // u64
const CC_QUEUE_AVAIL: usize = 0x28; // u64
const CC_QUEUE_USED: usize = 0x30; // u64

const ST_ACK: u8 = 1;
const ST_DRIVER: u8 = 2;
const ST_DRIVER_OK: u8 = 4;
const ST_FEATURES_OK: u8 = 8;

pub const MSIX_NO_VECTOR: u16 = 0xFFFF;

pub const Dev = struct {
    pdev: *const pci.Device,
    common: usize = 0, // mapped window VAs (identity: VA == phys)
    notify: usize = 0,
    notify_mul: u32 = 0,
    isr: usize = 0,
    dcfg: usize = 0,
    nqueues: u16 = 0,
};

fn rd(base: usize, off: usize, comptime T: type) T {
    const p: *volatile T = @ptrFromInt(base + off);
    return p.*;
}
fn wr(base: usize, off: usize, v: anytype) void {
    const p: *volatile @TypeOf(v) = @ptrFromInt(base + off);
    p.* = v;
}

fn mapWindow(phys: u64, len: u64) ?usize {
    if (!mmio.map(phys, len)) return null;
    return @intCast(phys); // identity — VA == phys
}

// open: walk the vendor-cap list and map every window the transport
// needs. Returns null loudly (serial says which window) when a required
// window is absent — a modern virtio device MUST offer common+notify+isr.
pub fn open(pdev: *const pci.Device) ?Dev {
    var d: Dev = .{ .pdev = pdev };
    const bus = pdev.bus;
    const slot = pdev.slot;
    const func = pdev.func;
    var from: u8 = 0;
    while (true) {
        const off = pci.capNext(pdev, 0x09, from);
        if (off == 0) break;
        from = off;
        const ty = pci.read8(bus, slot, func, off + 3);
        const bar = pci.read8(bus, slot, func, off + 4);
        if (bar >= 6 or (pdev.bars[bar] & 1) != 0) continue; // I/O BAR isn't a window
        const coff = pci.read32(bus, slot, func, off + 8);
        const len = pci.read32(bus, slot, func, off + 12);
        const phys = pci.barPhys(pdev, bar) + coff;
        switch (ty) {
            CFG_COMMON => d.common = mapWindow(phys, len) orelse return null,
            CFG_NOTIFY => {
                d.notify = mapWindow(phys, len) orelse return null;
                d.notify_mul = pci.read32(bus, slot, func, off + 16);
            },
            CFG_ISR => d.isr = mapWindow(phys, len) orelse return null,
            CFG_DEVICE => d.dcfg = mapWindow(phys, len) orelse return null,
            else => {},
        }
    }
    if (d.common == 0 or d.notify == 0 or d.isr == 0) {
        koru_say("virtiopci: missing window common=");
        koru_putdec(@intFromBool(d.common != 0));
        koru_say(" notify=");
        koru_putdec(@intFromBool(d.notify != 0));
        koru_say(" isr=");
        koru_putdec(@intFromBool(d.isr != 0));
        koru_say("\n");
        return null;
    }
    pci.setCommand(pdev, pci.command(pdev) | 0x6); // mem space + bus master
    d.nqueues = rd(d.common, CC_NUM_QUEUES, u16);
    return d;
}

// The virtio status handshake: reset, ack, driver; caller then runs
// negFeatures, sets queues, and calls driverOk last.
pub fn statusBegin(d: *const Dev) void {
    wr(d.common, CC_STATUS, @as(u8, 0));
    while (rd(d.common, CC_STATUS, u8) != 0) {}
    wr(d.common, CC_STATUS, ST_ACK);
    wr(d.common, CC_STATUS, ST_ACK | ST_DRIVER);
}
pub fn driverOk(d: *const Dev) void {
    wr(d.common, CC_STATUS, rd(d.common, CC_STATUS, u8) | ST_DRIVER_OK);
}
pub fn devStatus(d: *const Dev) u8 {
    return rd(d.common, CC_STATUS, u8);
}

// Feature negotiation: read both dwords of device_feature, accept the
// subset the caller wants, FEATURES_OK, then RE-READ status — the
// device may reject the set, and only a re-read proves the handshake.
pub fn negFeatures(d: *const Dev, want_lo: u32, want_hi: u32) bool {
    wr(d.common, CC_DEV_FEATURE_SEL, @as(u32, 0));
    const dev_lo = rd(d.common, CC_DEV_FEATURE, u32);
    wr(d.common, CC_DEV_FEATURE_SEL, @as(u32, 1));
    const dev_hi = rd(d.common, CC_DEV_FEATURE, u32);
    wr(d.common, CC_DRV_FEATURE_SEL, @as(u32, 0));
    wr(d.common, CC_DRV_FEATURE, want_lo & dev_lo);
    wr(d.common, CC_DRV_FEATURE_SEL, @as(u32, 1));
    wr(d.common, CC_DRV_FEATURE, want_hi & dev_hi);
    wr(d.common, CC_STATUS, rd(d.common, CC_STATUS, u8) | ST_FEATURES_OK);
    return (rd(d.common, CC_STATUS, u8) & ST_FEATURES_OK) != 0;
}

// ---- the split virtqueue -------------------------------------------------

pub const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };
pub const DESC_NEXT: u16 = 1;
pub const DESC_WRITE: u16 = 2;

pub const Queue = struct {
    idx: u16,
    size: u16,
    descs: [*]volatile Desc,
    avail_flags: *volatile u16,
    avail_idx: *volatile u16,
    avail_ring: [*]volatile u16,
    used_base: usize, // what CC_QUEUE_USED gets — the Used STRUCT's base
    used_idx: *volatile u16, // used_base+2 — the field, not the struct
    used_ring: [*]volatile extern struct { id: u32, len: u32 },
    notify: usize, // VA of this queue's doorbell slot
    last_used: u16 = 0,
    free_head: u16 = 0,
};

// queueBind: caller owns the ring memory (static arena — physically
// contiguous under the identity map). Program all three addresses,
// the MSI-X vector (MSIX_NO_VECTOR for polled), compute the doorbell,
// then enable.
pub fn queueBind(d: *const Dev, q: *Queue, msix_entry: u16) bool {
    wr(d.common, CC_QUEUE_SEL, q.idx);
    const offered = rd(d.common, CC_QUEUE_SIZE, u16);
    if (offered < q.size) q.size = offered;
    wr(d.common, CC_QUEUE_DESC, @intFromPtr(q.descs));
    wr(d.common, CC_QUEUE_AVAIL, @intFromPtr(q.avail_flags));
    wr(d.common, CC_QUEUE_USED, q.used_base);
    wr(d.common, CC_QUEUE_MSIX, msix_entry);
    if (msix_entry != MSIX_NO_VECTOR)
        if (rd(d.common, CC_QUEUE_MSIX, u16) != msix_entry) return false;
    const noff = rd(d.common, CC_QUEUE_NOFF, u16);
    q.notify = d.notify + @as(usize, noff) * d.notify_mul;
    wr(d.common, CC_QUEUE_ENABLE, @as(u16, 1));
    return rd(d.common, CC_QUEUE_ENABLE, u16) == 1;
}

pub fn kick(d: *const Dev, q: *const Queue) void {
    _ = d;
    const p: *volatile u16 = @ptrFromInt(q.notify);
    p.* = q.idx;
    asm volatile ("mfence" ::: .{ .memory = true });
}

pub fn isrRead(d: *const Dev) u8 {
    return rd(d.isr, 0, u8);
}

pub fn setConfigVector(d: *const Dev, entry: u16) void {
    wr(d.common, CC_MSIX_CONFIG, entry);
}

const std = @import("std");
