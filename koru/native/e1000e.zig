// koru/native e1000e — TX-only Intel gigabit NIC driver.
//
// Ported from iPXE src/drivers/net/intel.c + intel.h (Michael Brown,
// GPL2_OR_LATER_OR_UBDL — reference copy in session/net-telemetry/ref/).
// Covers the I219 family (PCH-integrated PHY, NO_PHY_RST + RST_HANG
// errata flags) and the 82574L/8254x parts — the latter so QEMU's
// `-device e1000e` (82574L) and the default `-nic user,model=e1000`
// (82540EM) exercise the same code path the ThinkPad's I219-LM runs.
//
// TX-only per commission: one legacy-format TX descriptor ring, polled
// completion, no RX ring, no interrupts. Frame buffers and the descriptor
// ring are static .bss — the flat image is identity-mapped below 4 GiB,
// so a .bss VA IS the DMA address. No pmm involvement, no copies through
// a bounce buffer: the caller's frame is memcpy'd into the slot buffer
// (a .bss slot is still cheaper than trusting arbitrary caller memory
// layout, and slot-per-descriptor keeps N frames in flight).
//
// Every wait is bounded — a hung NIC reports and returns false, it can
// never stall kmain. All diagnostics go to serial (koru_say) AND are
// mirrored into net markers by the caller where a stage matters.

const std = @import("std");
const pci = @import("pci");
const mmio = @import("mmio");

extern fn koru_say(s: [*:0]const u8) void;
extern fn ukplat_monotonic_clock() callconv(.c) u64; // ns, TSC-calibrated

fn say(s: [*:0]const u8) void {
    koru_say(s);
}
fn sayf(comptime f: []const u8, a: anytype) void {
    var b: [192]u8 = undefined;
    const s = std.fmt.bufPrintZ(&b, f ++ "\n", a) catch return;
    say(s.ptr);
}

// ---- registers (intel.h offsets) ------------------------------------------

const R_CTRL: usize = 0x00000;
const R_STATUS: usize = 0x00008;
const R_EERD: usize = 0x00014;
const R_TCTL: usize = 0x00400;
const R_TD: usize = 0x03800; // TX descriptor block: +0 DBAL +4 DBAH +8 DLEN +0x10 DH +0x18 DT +0x28 DCTL
const R_RAL0: usize = 0x05400;
const R_RAH0: usize = 0x05404;
const R_FEXTNVM11: usize = 0x05bbc;

const CTRL_LRST: u32 = 0x00000008;
const CTRL_ASDE: u32 = 0x00000020;
const CTRL_SLU: u32 = 0x00000040;
const CTRL_FRCSPD: u32 = 0x00000800;
const CTRL_FRCDPLX: u32 = 0x00001000;
const CTRL_RST: u32 = 0x04000000;
const CTRL_PHY_RST: u32 = 0x80000000;

const STATUS_LU: u32 = 0x00000002;

const EERD_START: u32 = 0x00000001;
const EERD_DONE_SMALL: u32 = 0x00000010;
const EERD_DONE_LARGE: u32 = 0x00000002;

const TCTL_EN: u32 = 0x00000002;
const TCTL_PSP: u32 = 0x00000008;
const TCTL_CT_DEFAULT: u32 = 0x000000F0; // 0x0f << 4
const TCTL_COLD_DEFAULT: u32 = 0x00040000; // 0x40 << 12
const TCTL_CT_MASK: u32 = 0x00000FF0;
const TCTL_COLD_MASK: u32 = 0x003FF000;

const DCTL_ENABLE: u32 = 0x02000000;
const RAH0_AV: u32 = 0x80000000;
const FEXTNVM11_WTF: u32 = 0x00002000;

const DESC_CMD_RS: u8 = 0x08;
const DESC_CMD_IFCS: u8 = 0x02;
const DESC_CMD_EOP: u8 = 0x01;
const DESC_STATUS_DD: u32 = 0x00000001;

const BAR_SIZE: u64 = 128 * 1024;
const RESET_DELAY_NS: u64 = 20 * 1_000_000;
const EERD_MAX_NS: u64 = 100 * 1_000_000;
const TX_MAX_NS: u64 = 50 * 1_000_000;
const LINK_WAIT_NS: u64 = 5 * 1_000_000_000; // PHY autoneg on a cold P2P link
const TX_PROBE_NS: u64 = 200 * 1_000_000;

// ---- device table ----------------------------------------------------------
// iPXE flag bits, only the ones this driver honours.
const F_NO_PHY_RST: u32 = 0x1;
const F_RST_HANG: u32 = 0x2;
const F_I219: u32 = F_NO_PHY_RST | F_RST_HANG;

const DevId = struct { dev: u16, flags: u32 };
const DEV_IDS = [_]DevId{
    // I219 family — every variant iPXE ships a ROM for
    .{ .dev = 0x0d4c, .flags = F_I219 }, .{ .dev = 0x0d4d, .flags = F_I219 },
    .{ .dev = 0x0d4e, .flags = F_I219 }, .{ .dev = 0x0d4f, .flags = F_I219 },
    .{ .dev = 0x0d53, .flags = F_I219 }, .{ .dev = 0x0d55, .flags = F_I219 },
    .{ .dev = 0x0dc5, .flags = F_I219 }, .{ .dev = 0x0dc6, .flags = F_I219 },
    .{ .dev = 0x156f, .flags = F_I219 }, .{ .dev = 0x1570, .flags = F_I219 },
    .{ .dev = 0x15b7, .flags = F_I219 }, .{ .dev = 0x15b8, .flags = F_I219 },
    .{ .dev = 0x15b9, .flags = F_I219 }, .{ .dev = 0x15bb, .flags = F_I219 },
    .{ .dev = 0x15bc, .flags = F_I219 }, .{ .dev = 0x15bd, .flags = F_I219 },
    .{ .dev = 0x15be, .flags = F_I219 }, .{ .dev = 0x15d6, .flags = F_I219 },
    .{ .dev = 0x15d7, .flags = F_I219 }, .{ .dev = 0x15d8, .flags = F_I219 },
    .{ .dev = 0x15df, .flags = F_I219 }, .{ .dev = 0x15e0, .flags = F_I219 },
    .{ .dev = 0x15e1, .flags = F_I219 }, .{ .dev = 0x15e2, .flags = F_I219 },
    .{ .dev = 0x15e3, .flags = F_I219 }, .{ .dev = 0x15f4, .flags = F_I219 },
    .{ .dev = 0x15f5, .flags = F_I219 }, .{ .dev = 0x15f9, .flags = F_I219 },
    .{ .dev = 0x15fa, .flags = F_I219 }, .{ .dev = 0x15fb, .flags = F_I219 },
    .{ .dev = 0x15fc, .flags = F_I219 }, .{ .dev = 0x1a1c, .flags = F_I219 },
    .{ .dev = 0x1a1d, .flags = F_I219 }, .{ .dev = 0x1a1e, .flags = F_I219 },
    .{ .dev = 0x1a1f, .flags = F_I219 }, .{ .dev = 0x550a, .flags = F_I219 },
    .{ .dev = 0x550b, .flags = F_I219 }, .{ .dev = 0x550c, .flags = F_I219 },
    .{ .dev = 0x550d, .flags = F_I219 }, .{ .dev = 0x550e, .flags = F_I219 },
    .{ .dev = 0x550f, .flags = F_I219 },
    // QEMU e1000e = 82574L; default -nic e1000 = 82540EM
    .{ .dev = 0x10d3, .flags = 0 }, .{ .dev = 0x10f6, .flags = 0 },
    .{ .dev = 0x100e, .flags = 0 },
};

// ---- state -----------------------------------------------------------------

var regs: [*]volatile u32 = undefined;
var flags: u32 = 0;
var up: bool = false;
var mac: [6]u8 = undefined;
var link_up: bool = false;
var nic: ?*const pci.Device = null; // kept for live command-reg reads + rearm

const TX_N: usize = 32; // power of two — prod/cons mask directly
const TX_BUFSZ: usize = 512;

const Desc = extern struct {
    addr: u64,
    length: u16,
    flags: u8,
    command: u8,
    status: u32,
};
comptime {
    if (@sizeOf(Desc) != 16) @compileError("desc must be 16 bytes");
}

var tx_descs: [TX_N]Desc align(4096) = undefined; // page-aligned — iPXE ring erratum
var tx_bufs: [TX_N][TX_BUFSZ]u8 align(4096) = undefined;
var tx_prod: usize = 0;
var tx_cons: usize = 0;
var tx_sent: u64 = 0;
var tx_completed: u64 = 0;
var tx_failed: u64 = 0;
var tx_dropped: u64 = 0; // ring-full drops — dead-NIC signal, non-blocking
var last_tx_wait_ok: bool = false; // result of the most recent synchronous probe

// diag: what init actually did, for the shell 'net' command and the
// KORU diag marker — real silicon may violate every assumption below.
pub const Diag = struct {
    stage: u8 = 0, // 0 none 1 pci-found 2 bar-mapped 3 reset 4 mac 5 ring 6 linkwait
    bar0: u64 = 0,
    cmd: u32 = 0,     // PCI command reg readback
    ctrl: u32 = 0,    // CTRL readback post-reset
    status: u32 = 0,  // STATUS readback post-reset
    tctl: u32 = 0,    // TCTL readback post-arm
    td_bal: u32 = 0, td_bah: u32 = 0, td_len: u32 = 0,
    td_h: u32 = 0, td_t: u32 = 0,
    ral0: u32 = 0, rah0: u32 = 0,
    mac_src: u8 = 0,  // 0 none 1 ral0/rah0 2 eeprom
};
var diag: Diag = .{};
pub fn diagInfo() Diag {
    return diag;
}
pub const Stats = struct { sent: u64, completed: u64, failed: u64, dropped: u64 };
pub fn stats() Stats {
    return .{ .sent = tx_sent, .completed = tx_completed, .failed = tx_failed, .dropped = tx_dropped };
}

fn rd(off: usize) u32 {
    return regs[off / 4];
}
fn wr(off: usize, v: u32) void {
    regs[off / 4] = v;
}

fn delayNs(ns: u64) void {
    const t0 = ukplat_monotonic_clock();
    while (ukplat_monotonic_clock() - t0 < ns) {
        asm volatile ("pause");
    }
}

fn membar() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

// ---- reset + MAC ------------------------------------------------------------

fn reset() void {
    const orig_ctrl = rd(R_CTRL);
    const orig_status = rd(R_STATUS);

    // Always reset MAC — required to reset TX/RX rings (iPXE intel_reset).
    wr(R_CTRL, orig_ctrl | CTRL_RST);
    delayNs(RESET_DELAY_NS);

    var ctrl = orig_ctrl | CTRL_ASDE | CTRL_SLU;
    ctrl &= ~(CTRL_LRST | CTRL_FRCSPD | CTRL_FRCDPLX);
    wr(R_CTRL, ctrl);
    delayNs(RESET_DELAY_NS);

    const status = rd(R_STATUS);
    if ((flags & F_NO_PHY_RST) != 0 or (status & STATUS_LU) != 0) {
        sayf("e1000e: mac reset only ({x}/{x} was {x}/{x})", .{ ctrl, status, orig_ctrl, orig_status });
        return;
    }

    // PHY+MAC reset — skipped for I219 (broken) and whenever link is up.
    wr(R_CTRL, ctrl | CTRL_RST | CTRL_PHY_RST);
    delayNs(RESET_DELAY_NS);
    wr(R_CTRL, ctrl); // PHY reset is not self-clearing on all models
    delayNs(RESET_DELAY_NS);
    sayf("e1000e: mac+phy reset ({x}/{x} was {x}/{x})", .{ ctrl, rd(R_STATUS), orig_ctrl, orig_status });
}

fn eerdReadWord(addr: u32, shift: u5) ?u16 {
    const t0 = ukplat_monotonic_clock();
    wr(R_EERD, EERD_START | (addr << shift));
    while (ukplat_monotonic_clock() - t0 < EERD_MAX_NS) {
        const v = rd(R_EERD);
        const done: u32 = if (shift == 8) EERD_DONE_SMALL else EERD_DONE_LARGE;
        if (v & done != 0) return @intCast((v >> 16) & 0xFFFF);
        asm volatile ("pause");
    }
    return null;
}

fn fetchMacEeprom() ?[6]u8 {
    // Probe EERD format with a word-0 read (iPXE intel_init_eeprom).
    const t0 = ukplat_monotonic_clock();
    wr(R_EERD, EERD_START);
    var shift: u5 = 8;
    var ok = false;
    while (ukplat_monotonic_clock() - t0 < EERD_MAX_NS) {
        const v = rd(R_EERD);
        if (v & EERD_DONE_LARGE != 0) {
            shift = 2;
            ok = true;
            break;
        }
        if (v & EERD_DONE_SMALL != 0) {
            ok = true;
            break;
        }
        asm volatile ("pause");
    }
    if (!ok) {
        say("e1000e: EERD format probe timed out\n");
        return null;
    }
    var m: [6]u8 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const w = eerdReadWord(@intCast(i), shift) orelse return null;
        m[2 * i] = @intCast(w & 0xFF);
        m[2 * i + 1] = @intCast(w >> 8);
    }
    return m;
}

fn fetchMac() void {
    // Autoloaded RAL0/RAH0 first — most e1000e parts load NVM MAC here.
    const lo = rd(R_RAL0);
    const hi = rd(R_RAH0);
    var m: [6]u8 = undefined;
    m[0] = @truncate(lo);
    m[1] = @truncate(lo >> 8);
    m[2] = @truncate(lo >> 16);
    m[3] = @truncate(lo >> 24);
    m[4] = @truncate(hi);
    m[5] = @truncate(hi >> 8);
    const valid = m[0] | m[1] | m[2] | m[3] | m[4] | m[5] != 0 and (m[0] & 1) == 0;
    if (valid) {
        mac = m;
        diag.ral0 = lo;
        diag.rah0 = hi;
        diag.mac_src = 1;
        sayf("e1000e: autoloaded mac {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ m[0], m[1], m[2], m[3], m[4], m[5] });
        return;
    }
    diag.ral0 = lo;
    diag.rah0 = hi;
    if (fetchMacEeprom()) |em| {
        mac = em;
        diag.mac_src = 2;
        sayf("e1000e: eeprom mac {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{ em[0], em[1], em[2], em[3], em[4], em[5] });
        return;
    }
    say("e1000e: no MAC address — refusing to come up\n");
}

// ---- TX ring ----------------------------------------------------------------

fn ringSetup() void {
    const base = @intFromPtr(&tx_descs);
    wr(R_TD + 0x00, @truncate(base)); // TDBAL
    wr(R_TD + 0x04, @truncate(base >> 32)); // TDBAH
    wr(R_TD + 0x08, TX_N * @sizeOf(Desc)); // TDLEN
    wr(R_TD + 0x10, 0); // TDH
    wr(R_TD + 0x18, 0); // TDT
    wr(R_TD + 0x28, rd(R_TD + 0x28) | DCTL_ENABLE); // TDCTL

    // I219 reset-hang errata (iPXE INTEL_RST_HANG): FEXTNVM11 bit13 must
    // be set or the next reset wedges the datapath.
    if ((flags & F_RST_HANG) != 0) {
        wr(R_FEXTNVM11, rd(R_FEXTNVM11) | FEXTNVM11_WTF);
    }

    var tctl = rd(R_TCTL);
    tctl &= ~(TCTL_CT_MASK | TCTL_COLD_MASK);
    tctl |= TCTL_EN | TCTL_PSP | TCTL_CT_DEFAULT | TCTL_COLD_DEFAULT;
    wr(R_TCTL, tctl);

    // Program RAL0/RAH0 — RX filter table; correct for TX-only too and
    // keeps the autoloaded value honest if it was stale.
    const lo: u32 = @bitCast(mac[0..4].*);
    const hi0: u32 = @as(u32, mac[4]) | (@as(u32, mac[5]) << 8);
    wr(R_RAL0, lo);
    wr(R_RAH0, hi0 | RAH0_AV);
}

// ---- public surface ----------------------------------------------------------

pub fn macAddr() *const [6]u8 {
    return &mac;
}
pub fn isUp() bool {
    return up;
}
pub fn linkIsUp() bool {
    return link_up;
}

// liveCommand: read the NIC's PCI command register NOW — BME (bit2, 0x4)
// cleared = MMIO alive but DMA dead, the exact post-KMS wire-death split.
pub fn liveCommand() u16 {
    const d = nic orelse return 0;
    return pci.command(d);
}

// rearm: re-assert MEM+BM, reset ring pointers, clear stale DD bits, and
// re-run ringSetup — the 'netfix' experiment. If TX resumes after this,
// the stall was a state/BME/power issue (fixable by re-arming post-modeset);
// if not, the engine is held at a lower level (IOMMU/VT-d or reset-wedge).
pub fn rearm() bool {
    if (!up) return false;
    const d = nic orelse return false;
    pci.setCommand(d, pci.command(d) | 0x6);
    tx_prod = 0;
    tx_cons = 0;
    for (tx_descs[0..]) |*dd| dd.status = 0;
    ringSetup();
    return true;
}

// tx: hand one Ethernet frame (14B header onward, no FCS — IFCS adds it)
// to the ring. Polls the slot's DD bit before reuse; bounded wait, a
// stuck descriptor reports false rather than hanging the caller.
// submit: queue one frame, return slot index or null when refused.
fn submit(frame: []const u8) ?usize {
    if (!up) return null;
    if (frame.len == 0 or frame.len > TX_BUFSZ) {
        sayf("e1000e: tx refused len={d}", .{frame.len});
        tx_failed += 1;
        return null;
    }
    if (tx_prod - tx_cons >= TX_N) {
        // ring full — poll the oldest DD bit ONCE, non-blocking. Telemetry
        // is fire-and-forget: a dead NIC (DD never sets post-KMS) must
        // drop packets, never spin 50ms per call and stall the compositor.
        const dv: *volatile Desc = @ptrCast(&tx_descs[tx_cons & (TX_N - 1)]);
        if (dv.status & DESC_STATUS_DD == 0) {
            tx_dropped += 1;
            return null;
        }
        dv.status = 0;
        tx_cons += 1;
        tx_completed += 1;
    }
    const slot = tx_prod & (TX_N - 1);
    const d = &tx_descs[slot];
    @memcpy(tx_bufs[slot][0..frame.len], frame);
    d.* = .{
        .addr = @intFromPtr(&tx_bufs[slot]),
        .length = @intCast(frame.len),
        .flags = 0,
        .command = DESC_CMD_RS | DESC_CMD_IFCS | DESC_CMD_EOP,
        .status = 0,
    };
    membar();
    tx_prod += 1;
    link_up = (rd(R_STATUS) & STATUS_LU) != 0; // live link state, one MMIO read
    wr(R_TD + 0x18, @intCast(tx_prod & (TX_N - 1))); // TDT = tail index
    tx_sent += 1;
    return slot;
}

// waitDone: poll a slot's DD bit up to timeoutNs. The only TX-completion
// oracle available without RX — distinguishes "descriptor never
// completed" (ring/setup broken) from "completed but nothing on wire"
// (link/L2/cable problem).
pub fn waitDone(slot: usize, timeoutNs: u64) bool {
    const dv: *volatile Desc = @ptrCast(&tx_descs[slot & (TX_N - 1)]);
    const t0 = ukplat_monotonic_clock();
    while (dv.status & DESC_STATUS_DD == 0) {
        if (ukplat_monotonic_clock() - t0 > timeoutNs) return false;
        asm volatile ("pause");
    }
    return true;
}

pub fn lastTxWaitOk() bool {
    return last_tx_wait_ok;
}

// tx: fire-and-forget queue (boot markers — never stall kmain).
pub fn tx(frame: []const u8) bool {
    return submit(frame) != null;
}

// txProbe: synchronous send + DD wait — the shell 'udp'/'ping' oracle.
pub fn txProbe(frame: []const u8, timeoutNs: u64) bool {
    const slot = submit(frame) orelse return false;
    last_tx_wait_ok = waitDone(slot, timeoutNs);
    if (last_tx_wait_ok) tx_completed += 1;
    return last_tx_wait_ok;
}

// init: find the NIC in pci.devices, map BAR0, reset, fetch MAC, arm TX.
// Returns true when the ring is live; every failure says why on serial
// and returns false — telemetry must never take the boot down with it.
pub fn init() bool {
    var found: ?*const pci.Device = null;
    var f: u32 = 0;
    for (pci.devices[0..pci.count]) |*d| {
        if (d.vendor != 0x8086 or d.class != 0x02 or d.subclass != 0x00) continue;
        for (DEV_IDS) |id| {
            if (d.device == id.dev) {
                found = d;
                f = id.flags;
                break;
            }
        }
        if (found != null) break;
    }
    const d = found orelse {
        say("e1000e: no supported Intel NIC in pci table — net down\n");
        return false;
    };
    flags = f;
    nic = d;
    diag.stage = 1;
    sayf("e1000e: {x}:{x}.{x} dev={x} class={x}/{x} flags={x}", .{ d.bus, d.slot, d.func, d.device, d.class, d.subclass, flags });

    if ((d.bars[0] & 1) != 0) {
        say("e1000e: BAR0 is I/O space — this driver is MMIO-only\n");
        return false;
    }
    const bar0 = pci.barPhys(d, 0);
    diag.bar0 = bar0;
    if (!mmio.map(bar0, BAR_SIZE)) {
        say("e1000e: BAR0 map refused\n");
        return false;
    }
    diag.stage = 2;
    regs = @ptrFromInt(@as(usize, @intCast(bar0)));

    pci.setCommand(d, pci.command(d) | 0x6); // MEM + BM
    diag.cmd = pci.command(d);

    reset();
    diag.stage = 3;
    diag.ctrl = rd(R_CTRL);
    diag.status = rd(R_STATUS);
    fetchMac();
    if (mac[0] | mac[1] | mac[2] | mac[3] | mac[4] | mac[5] == 0) return false;
    diag.stage = 4;

    ringSetup();
    diag.stage = 5;
    diag.tctl = rd(R_TCTL);
    diag.td_bal = rd(R_TD + 0x00);
    diag.td_bah = rd(R_TD + 0x04);
    diag.td_len = rd(R_TD + 0x08);
    diag.td_h = rd(R_TD + 0x10);
    diag.td_t = rd(R_TD + 0x18);

    // PHY autoneg on a cold P2P link takes ~1-2s — the old code read LU
    // once at ~100ms and fired every boot marker into a dead link.
    // Wait bounded; proceed either way (markers attempted, honestly).
    {
        const t0 = ukplat_monotonic_clock();
        while ((rd(R_STATUS) & STATUS_LU) == 0 and
               ukplat_monotonic_clock() - t0 < LINK_WAIT_NS)
        {
            asm volatile ("pause");
        }
    }
    diag.stage = 6;
    link_up = (rd(R_STATUS) & STATUS_LU) != 0;
    diag.status = rd(R_STATUS);
    up = true;
    sayf("e1000e: tx ring armed — link={} mac={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} st={x} cmd={x} tctl={x}", .{ link_up, mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], diag.status, diag.cmd, diag.tctl });
    return true;
}

// liveStatus: fresh STATUS register read for the shell — never cached.
pub fn liveStatus() u32 {
    if (!up) return 0;
    return rd(R_STATUS);
}
