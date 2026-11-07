// koru/native i915/dp — DisplayPort link model + DPCD helpers,
// ported from libgfxinit hw-gfx.ads types + hw-gfx-dp_info.adb/.ads
// (coreboot, GPL-2.0), reduced to the eDP-on-DP_A path.
//
// AUX transactions live in aux.zig (dp_aux_ch/dp_aux_request port).

const mmio = @import("mmio.zig");
const aux = @import("aux.zig");

pub const DP_A: u32 = 0;

pub const Bandwidth = enum(u8) { b1_62 = 0, b2_7 = 1, b5_4 = 2 };
pub const LaneCount = enum(u8) { l1 = 1, l2 = 2, l4 = 4 };

pub fn symbolRate(b: Bandwidth) u64 {
    return switch (b) {
        .b1_62 => 162_000_000,
        .b2_7 => 270_000_000,
        .b5_4 => 540_000_000,
    };
}
pub fn laneCountInt(l: LaneCount) u64 {
    return switch (l) {
        .l1 => 1,
        .l2 => 2,
        .l4 => 4,
    };
}

pub const DPCaps = struct {
    rev: u8 = 0,
    maxLinkRate: Bandwidth = .b1_62,
    maxLaneCount: LaneCount = .l1,
    tps3Supported: bool = false,
    enhancedFraming: bool = false,
    noAuxHandshake: bool = false,
    auxRdInterval: u8 = 0,
};

pub const DPLink = struct {
    rx: DPCaps = .{},
    laneCount: LaneCount = .l1,
    bandwidth: Bandwidth = .b1_62,
    enhancedFraming: bool = false,
    opportunisticTraining: bool = false,
};

pub const Mode = struct {
    dotclock: u64 = 0,
    hVisible: u32 = 0,
    hSyncBegin: u32 = 0,
    hSyncEnd: u32 = 0,
    hTotal: u32 = 0,
    vVisible: u32 = 0,
    vSyncBegin: u32 = 0,
    vSyncEnd: u32 = 0,
    vTotal: u32 = 0,
    hSyncActiveHigh: bool = false,
    vSyncActiveHigh: bool = false,
    bpc: u64 = 8,
    hdmiSink: bool = false,
};

// M1920x1080_60 from hw-gfx.ads.
pub const M1920x1080_60 = Mode{
    .dotclock = 60 * (2185 * 1135),
    .hVisible = 1920, .hSyncBegin = 2008, .hSyncEnd = 2052, .hTotal = 2185,
    .vVisible = 1080, .vSyncBegin = 1084, .vSyncEnd = 1089, .vTotal = 1135,
    .hSyncActiveHigh = false, .vSyncActiveHigh = false,
    .bpc = 8, .hdmiSink = false,
};

// ---- AUX payload plumbing (aux.zig provides the channel) -------------------

pub fn auxRead(port: u32, addr: u32, buf: []u8) bool {
    _ = port; // DP_A only — channel is hardwired in aux.zig
    return aux.auxRead(addr, buf);
}
pub fn auxWrite(port: u32, addr: u32, buf: []const u8) bool {
    _ = port;
    return aux.auxWrite(addr, buf);
}

// ---- DP_Info port -----------------------------------------------------------

// Read_Caps: DPCD 0x00000..0x0000E (15 bytes).
pub fn readCaps(link: *DPLink) bool {
    var data: [15]u8 = undefined;
    if (!auxRead(DP_A, 0x00000, &data)) return false;

    link.rx.rev = data[0];
    link.rx.maxLinkRate = switch (data[1]) {
        0x06 => .b1_62,
        0x0a => .b2_7,
        0x14 => .b5_4,
        else => if (data[1] > 0x14) .b5_4 else .b1_62,
    };
    link.rx.maxLaneCount = switch (data[2] & 0x1f) {
        0, 1 => .l1,
        2, 3 => .l2,
        else => .l4,
    };
    link.rx.tps3Supported = (data[2] & 0x40) != 0;
    link.rx.enhancedFraming = (data[2] & 0x80) != 0;
    link.rx.noAuxHandshake = (data[3] & 0x40) != 0;
    link.rx.auxRdInterval = data[14] & 0x7f;
    return true;
}

// Read_eDP_Rates: eDP 1.4+ carries per-link-rate entries at DPCD 0x10.
pub fn readEdpRates(link: *DPLink) void {
    var caps: [3]u8 = undefined;
    if (!auxRead(DP_A, 0x00700, &caps)) return;
    if (caps[0] < 3) return; // eDP_Rev_1_4 = 3
    var data: [16]u8 = undefined;
    if (!auxRead(DP_A, 0x00010, &data)) return;
    var maxRate: u64 = 0;
    var i: usize = 0;
    while (i < data.len / 2) : (i += 1) {
        const rate = @as(u64, data[i * 2]) | (@as(u64, data[i * 2 + 1]) << 8);
        if (rate == 0) break;
        maxRate = @max(maxRate, rate);
    }
    maxRate *= 20; // kHz -> Hz... (20 kHz units -> keep as-is: *20 gives kHz*20)
    if (maxRate >= 540_000) {
        link.rx.maxLinkRate = .b5_4;
    } else if (maxRate >= 270_000) {
        link.rx.maxLinkRate = .b2_7;
    } else if (maxRate >= 162_000) {
        link.rx.maxLinkRate = .b1_62;
    }
}

fn minimumLaneCount(link: *DPLink, mode: Mode) bool {
    const lanePixelPerSec = ((symbolRate(link.bandwidth) * 8) / 3) / mode.bpc;
    const count = (mode.dotclock + lanePixelPerSec - 1) / lanePixelPerSec;
    link.laneCount = switch (count) {
        1 => .l1,
        2 => .l2,
        3, 4 => .l4,
        else => return false,
    };
    return true;
}

pub fn preferredLinkSetting(link: *DPLink, mode: Mode) bool {
    link.bandwidth = link.rx.maxLinkRate;
    link.enhancedFraming = link.rx.enhancedFraming;
    if (!minimumLaneCount(link, mode)) return false;
    if (laneCountInt(link.laneCount) > laneCountInt(link.rx.maxLaneCount)) return false;
    return true;
}

pub fn nextLinkSetting(link: *DPLink, mode: Mode) bool {
    if (link.bandwidth == .b1_62) return false;
    link.bandwidth = switch (link.bandwidth) {
        .b5_4 => .b2_7,
        .b2_7 => .b1_62,
        .b1_62 => unreachable,
    };
    if (!minimumLaneCount(link, mode)) return false;
    return laneCountInt(link.laneCount) <= laneCountInt(link.rx.maxLaneCount);
}

// ---- M/N calculation (used by link training) --------------------------------

pub const M_N_Max: u64 = (1 << 24) - 1;

fn cancelMN(m: *u64, n: *u64, targetN: u64) void {
    // m,n <= 2^38 in callers; result must land <= M_N_Max
    m.* = m.* * targetN / n.*;
    n.* = targetN;
    while (m.* > M_N_Max) {
        m.* /= 2;
        n.* /= 2;
    }
}

// Calculate_M_N: returns (dataM,dataN,linkM,linkN).
pub fn calculateMN(link: DPLink, mode: Mode) struct { dm: u64, dn: u64, lm: u64, ln: u64 } {
    var m: u64 = 3 * mode.bpc * mode.dotclock;
    var n: u64 = 8 * symbolRate(link.bandwidth) * laneCountInt(link.laneCount);
    cancelMN(&m, &n, 0x80_0000);
    const dm = m;
    const dn = n;

    m = mode.dotclock;
    n = symbolRate(link.bandwidth);
    cancelMN(&m, &n, 0x08_0000);
    return .{ .dm = dm, .dn = dn, .lm = m, .ln = n };
}

// ---- link status (DPCD 0x202, 6 bytes) ---------------------------------------

pub const LaneStatus = packed struct {
    crDone: bool = false,
    chEqDone: bool = false,
    symLocked: bool = false,
    _pad: u1 = 0,
};
pub const LinkStatus = struct {
    lanes: [4]LaneStatus = @splat(.{}),
    interlaneAlignDone: bool = false,
    _pad: u15 = 0,
    adjust: [4]packed struct { vs: u2 = 0, emph: u2 = 0 } = @splat(.{}),
};

pub fn readLinkStatus(port: u32) ?LinkStatus {
    var data: [6]u8 = undefined;
    if (!auxRead(port, 0x202, &data)) return null;
    // lanes: byte0 = lane0|lane1 status nibbles? — actual layout: 2 bytes,
    // lane i status in bits [2i+1:2i] of bytes 0..1 (4 lanes over 2 bytes?)
    // DPCD 0x202-0x203: lane status, 2 bits per lane x4 lanes = 1 byte? No:
    // 0x202 = per-lane status bits for lanes 0-3 (1 byte), 0x203 reserved.
    // libgfxinit maps raw 6 bytes via unchecked conversion onto LinkStatus:
    //   lanes[4] at bits 0..15 -> bytes 0,1  (2 bits each)
    //   interlane at bit16 -> byte2 bit0
    //   adjust_requests at bits32..47 -> bytes4,5 (2 bits each x4)
    var st: LinkStatus = .{};
    const b01: u16 = @as(u16, data[0]) | (@as(u16, data[1]) << 8);
    inline for (0..4) |i| {
        const bits = (b01 >> @intCast(4 * i)) & 0xF;
        st.lanes[i] = .{
            .crDone = (bits & 1) != 0,
            .chEqDone = (bits & 2) != 0,
            .symLocked = (bits & 4) != 0,
        };
    }
    st.interlaneAlignDone = (data[2] & 1) != 0;
    const a45: u16 = @as(u16, data[4]) | (@as(u16, data[5]) << 8);
    inline for (0..4) |i| {
        const bits = (a45 >> @intCast(4 * i)) & 0xF;
        st.adjust[i] = .{ .vs = @intCast(bits & 3), .emph = @intCast((bits >> 2) & 3) };
    }
    return st;
}

pub fn allCRDone(st: LinkStatus, link: DPLink) bool {
    const n = laneCountInt(link.laneCount);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        if (!st.lanes[@intCast(i)].crDone) return false;
    }
    return true;
}
pub fn allEQDone(st: LinkStatus, link: DPLink) bool {
    const n = laneCountInt(link.laneCount);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const l = st.lanes[@intCast(i)];
        if (!(l.crDone and l.chEqDone and l.symLocked)) return false;
    }
    return st.interlaneAlignDone;
}
pub fn maxRequestedVS(st: LinkStatus, link: DPLink) u8 {
    var vs: u8 = 0;
    const n = laneCountInt(link.laneCount);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        vs = @max(vs, st.adjust[@intCast(i)].vs);
    }
    return vs;
}
pub fn maxRequestedEmph(st: LinkStatus, link: DPLink) u8 {
    var e: u8 = 0;
    const n = laneCountInt(link.laneCount);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        e = @max(e, st.adjust[@intCast(i)].emph);
    }
    return e;
}
