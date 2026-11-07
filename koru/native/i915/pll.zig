// koru/native i915/pll — PLL alloc + DPLL programming,
// ported from libgfxinit skylake/hw-gfx-gma-plls.adb,
// skylake/hw-gfx-gma-plls-dpll.adb, skylake/hw-gfx-gma-plls-dpll_0.adb
// (coreboot, GPL-2.0).
//
// PLLs.T = (Invalid_PLL, DPLL0, DPLL1, DPLL3, DPLL2) — order twisted so
// WRPLL1 (DPLL2) is last choice. Configurable = {DPLL1,DPLL3,DPLL2}.
// eDP on DIGI_A: Alloc tries DPLL_0.Check_Link_Rate first (reuse the
// VBT/BIOS-configured PLL0 if its link rate already matches), else
// Alloc_Configurable -> DPLL.On.

const mmio = @import("mmio.zig");
const R = mmio.R;
const types = @import("types.zig");
const dp = @import("dp.zig");
const std = @import("std");

pub const PLL = enum(u8) { Invalid, DPLL0, DPLL1, DPLL3, DPLL2 };
pub const Configurable = [3]PLL{ .DPLL1, .DPLL3, .DPLL2 };

// PLL -> register-value hint (what goes into DPLL_CTRL2 DDIx_SELECT)
fn registerValue(p: PLL) u32 {
    return switch (p) {
        .DPLL0 => 0,
        .DPLL1 => 1,
        .DPLL3 => 3,
        .DPLL2 => 2,
        .Invalid => 0,
    };
}
pub fn regVal(p: PLL) u32 {
    return registerValue(p);
}

const DPLL_CTL_PLL_ENABLE: u32 = 1 << 31;

fn dpllCtlReg(p: PLL) u32 {
    return switch (p) {
        .DPLL1 => R.LCPLL2_CTL,
        .DPLL2 => R.WRPLL_CTL_1,
        .DPLL3 => R.WRPLL_CTL_2,
        else => 0,
    };
}
fn dpllCfgr1Reg(p: PLL) u32 {
    return switch (p) {
        .DPLL1 => R.DPLL1_CFGR1,
        .DPLL2 => R.DPLL2_CFGR1,
        .DPLL3 => R.DPLL3_CFGR1,
        else => 0,
    };
}
fn dpllCfgr2Reg(p: PLL) u32 {
    return switch (p) {
        .DPLL1 => R.DPLL1_CFGR2,
        .DPLL2 => R.DPLL2_CFGR2,
        .DPLL3 => R.DPLL3_CFGR2,
        else => 0,
    };
}
// DPLL_CTRL1 field shifts per PLL slot
fn ctrl1Shift(p: PLL) u5 {
    return switch (p) { .DPLL1 => 6, .DPLL2 => 12, .DPLL3 => 18, else => 0 };
}
fn statusShift(p: PLL) u5 {
    return switch (p) { .DPLL1 => 8, .DPLL2 => 16, .DPLL3 => 24, else => 0 };
}
fn ctrl1Field(p: PLL, v: u32) u32 {
    return v << ctrl1Shift(p);
}
fn lockMask(p: PLL) u32 {
    return @as(u32, 1) << statusShift(p);
}

// ---- DPLL_0 (the "free" PLL0, VBT/BIOS configured) -------------------------

const DPLL0_LINK_RATE_MASK: u32 = 7 << 1;
const DPLL0_LINK_RATE_2700: u32 = 0 << 1;
const DPLL0_LINK_RATE_1350: u32 = 1 << 1;
const DPLL0_LINK_RATE_810: u32 = 2 << 1;
const DPLL0_OVERRIDE: u32 = 1;

fn checkLinkRateDpll0(linkRate: dp.Bandwidth) bool {
    const ctl1 = mmio.rd(R.DPLL_CTRL1);
    var ok = false;
    switch (ctl1 & DPLL0_LINK_RATE_MASK) {
        DPLL0_LINK_RATE_2700 => ok = linkRate == .b5_4,
        DPLL0_LINK_RATE_1350 => ok = linkRate == .b2_7,
        DPLL0_LINK_RATE_810 => ok = linkRate == .b1_62,
        else => ok = false,
    }
    return ok and (ctl1 & DPLL0_OVERRIDE) != 0;
}

// ---- DPLL (configurable WRPLL/LCPLL2) ---------------------------------------

const HDMI_MODE: u32 = 1 << 5;
const SSC: u32 = 1 << 4;
const LINK_RATE_MASK: u32 = 7 << 1;
fn linkRateBits(b: dp.Bandwidth) u32 {
    return switch (b) {
        .b5_4 => 0 << 1, // 2700MHz
        .b2_7 => 1 << 1, // 1350MHz
        .b1_62 => 2 << 1, // 810MHz
    };
}
const OVERRIDE: u32 = 1;

const CFGR1_FREQ_ENABLE: u32 = 1 << 31;
const CFGR1_FRAC_SHIFT: u6 = 9;
const CFGR1_FRAC_MASK: u32 = 0x7fff << 9;
const CFGR1_INT_MASK: u32 = 0x1ff;

const CFGR2_QDIV_SHIFT: u6 = 8;
const CFGR2_QDIV_MASK: u32 = 255 << 8;
const CFGR2_QDIV_MODE: u32 = 1 << 7;
const CFGR2_KDIV_SHIFT: u6 = 5;
const CFGR2_KDIV_MASK: u32 = 3 << 5;
const CFGR2_PDIV_SHIFT: u6 = 2;
const CFGR2_PDIV_MASK: u32 = 7 << 2;
const CFGR2_CF_MASK: u32 = 3;
const CF_9600: u32 = 0;
const CF_9000: u32 = 1;
const CF_8400: u32 = 3;

fn dpllOn(p: PLL, cfg: *const types.Port_Config) bool {
    if (cfg.display == .DP) {
        // DP/eDP: link-rate mode, no fractional DCO programming.
        mmio.unsetAndSet(R.DPLL_CTRL1,
            ctrl1Field(p, HDMI_MODE | SSC | LINK_RATE_MASK),
            ctrl1Field(p, linkRateBits(cfg.dp.bandwidth) | OVERRIDE));
        mmio.postingRead(R.DPLL_CTRL1);
    } else {
        // HDMI path: Calculate_DPLL fractional programming.
        var cf: u32 = undefined;
        var dco: u64 = undefined;
        var pdiv: u64 = undefined;
        var qdiv: u64 = undefined;
        var kdiv: u64 = undefined;
        if (!calculateDpll(cfg.mode.dotclock, &cf, &dco, &pdiv, &qdiv, &kdiv))
            return false;
        mmio.unsetAndSet(R.DPLL_CTRL1,
            ctrl1Field(p, SSC),
            ctrl1Field(p, HDMI_MODE | OVERRIDE));
        mmio.wr(dpllCfgr1Reg(p),
            CFGR1_FREQ_ENABLE |
            (((@as(u32, @intCast((dco * (1 << 15)) / 24_000_000))) & 0x7fff) << CFGR1_FRAC_SHIFT) |
            @as(u32, @intCast(dco / 24_000_000)));
        mmio.wr(dpllCfgr2Reg(p),
            (@as(u32, @intCast(qdiv)) << CFGR2_QDIV_SHIFT) |
            (if (qdiv != 1) CFGR2_QDIV_MODE else 0) |
            (kdivBits(kdiv) << CFGR2_KDIV_SHIFT) |
            (pdivBits(pdiv) << CFGR2_PDIV_SHIFT) |
            cf);
        mmio.postingRead(R.DPLL_CTRL1);
        mmio.postingRead(dpllCfgr1Reg(p));
        mmio.postingRead(dpllCfgr2Reg(p));
    }
    mmio.wr(dpllCtlReg(p), DPLL_CTL_PLL_ENABLE);
    return mmio.waitSet(R.DPLL_STATUS, lockMask(p), mmio.DefaultTimeoutMs);
}

fn kdivBits(k: u64) u32 {
    return switch (k) {
        5 => 0, 2 => 1, 3 => 2, 1 => 3, else => 0,
    };
}
fn pdivBits(p_: u64) u32 {
    return switch (p_) {
        1 => 0, 2 => 1, 3 => 2, 7 => 4, else => 4,
    };
}

// ---- Calculate_DPLL (HDMI/non-DP path) --------------------------------------

fn calculateDpll(
    dotclock: u64,
    centralFreq: *u32,
    dcoFreq: *u64,
    pdiv: *u64,
    qdiv: *u64,
    kdiv: *u64,
) bool {
    const CF_POS = [3]u64{ 9_600_000_000, 9_000_000_000, 8_400_000_000 };
    const EVEN_DIVS = [36]u64{
        4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28, 30, 32, 36, 40, 42, 44,
        48, 52, 54, 56, 60, 64, 66, 68, 70, 72, 76, 78, 80, 84, 88, 90,
        92, 96, 98,
    };
    const ODD_DIVS = [7]u64{ 3, 5, 7, 9, 15, 21, 35 };

    centralFreq.* = 0xFFFFFFFF; // CF_INVALID sentinel
    dcoFreq.* = 1;
    pdiv.* = 1;
    qdiv.* = 1;
    kdiv.* = 1;

    var minDev: i64 = std.math.minInt(i64);
    var found = false;
    var chosenCF: usize = 0;
    var chosenDiv: u64 = 0;
    var chosenDco: u64 = 0;

    // Even candidates first, then odd; stop at first parity with a hit.
    var parity: u32 = 0;
    while (parity < 2) : (parity += 1) {
        var cfIdx: usize = 0;
        while (cfIdx < 3) : (cfIdx += 1) {
            const tempCentral = CF_POS[cfIdx];
            const divs = if (parity == 0) &EVEN_DIVS else &ODD_DIVS;
            const count = if (parity == 0) EVEN_DIVS.len else ODD_DIVS.len;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const tempFreq = divs[i] * 5 * dotclock;
                var dev: i64 = undefined;
                var allowed: u64 = undefined;
                if (tempFreq > tempCentral) {
                    dev = @intCast(tempFreq - tempCentral);
                    allowed = tempCentral / 100; // Max_Pos_Deviation=1%
                } else {
                    dev = @intCast(tempCentral - tempFreq);
                    allowed = tempCentral * 6 / 100; // Max_Neg=6%
                }
                if (dev < minDev and dev < @as(i64, @intCast(allowed))) {
                    minDev = dev;
                    found = true;
                    chosenCF = cfIdx;
                    chosenDiv = divs[i];
                    chosenDco = tempFreq;
                }
            }
        }
        if (found) break;
    }
    if (!found) return false;

    centralFreq.* = switch (chosenCF) {
        0 => CF_9600, 1 => CF_9000, else => CF_8400,
    };
    dcoFreq.* = chosenDco;

    var div = chosenDiv;
    if (div % 2 == 0) {
        div /= 2;
        if (div == 1 or div == 3 or div == 5) {
            // 2,6,10
            pdiv.* = 2; qdiv.* = 1; kdiv.* = div;
        } else if (div % 2 == 0) {
            pdiv.* = 2; qdiv.* = div / 2; kdiv.* = 2;
        } else if (div % 3 == 0) {
            pdiv.* = 3; qdiv.* = div / 3; kdiv.* = 2;
        } else if (div % 7 == 0) {
            pdiv.* = 7; qdiv.* = div / 7; kdiv.* = 2;
        }
    } else if (div == 7 or div == 21 or div == 35) {
        pdiv.* = 7; qdiv.* = 1; kdiv.* = div / 7;
    } else if (div == 3 or div == 9 or div == 15) {
        pdiv.* = 3; qdiv.* = 1; kdiv.* = div / 3;
    } else if (div == 5) {
        pdiv.* = 5; qdiv.* = 1; kdiv.* = 1;
    }
    return true;
}

// ---- PLLs package state -----------------------------------------------------

const PLLState = struct {
    useCount: u2 = 0,
    usedForDP: bool = false,
    linkRate: dp.Bandwidth = .b1_62,
    mode: types.Mode_Type = types.Invalid_Mode,
};
var plls: [3]PLLState = @splat(.{});

pub fn initialize() void {
    plls = @splat(.{});
}

fn configMatches(pe: PLLState, cfg: *const types.Port_Config) bool {
    const isDP = cfg.display == .DP;
    return (pe.usedForDP == isDP) and
        ((pe.usedForDP and pe.linkRate == cfg.dp.bandwidth) or
         (!pe.usedForDP and pe.mode.dotclock == cfg.mode.dotclock));
}

pub const Alloc = struct { pll: PLL, ok: bool };
fn allocConfigurable(cfg: *const types.Port_Config) Alloc {
    // shareable?
    for (Configurable, 0..) |p, i| {
        if (plls[i].useCount != 0 and plls[i].useCount != 2 and configMatches(plls[i], cfg)) {
            plls[i].useCount += 1;
            return .{ .pll = p, .ok = true };
        }
    }
    // free?
    for (Configurable, 0..) |p, i| {
        if (plls[i].useCount == 0) {
            if (dpllOn(p, cfg)) {
                plls[i] = .{
                    .useCount = 1,
                    .usedForDP = cfg.display == .DP,
                    .linkRate = cfg.dp.bandwidth,
                    .mode = cfg.mode,
                };
                return .{ .pll = p, .ok = true };
            }
            return .{ .pll = .Invalid, .ok = false };
        }
    }
    return .{ .pll = .Invalid, .ok = false };
}

pub fn alloc(cfg: *const types.Port_Config) Alloc {
    if (cfg.port == .DIGI_A) {
        if (checkLinkRateDpll0(cfg.dp.bandwidth))
            return .{ .pll = .DPLL0, .ok = true };
    }
    return allocConfigurable(cfg);
}

pub fn free(p: PLL) void {
    const i: usize = switch (p) {
        .DPLL1 => 0, .DPLL3 => 1, .DPLL2 => 2, else => return,
    };
    if (plls[i].useCount != 0) {
        plls[i].useCount -= 1;
        if (plls[i].useCount == 0) dpllOff(p);
    }
}
fn dpllOff(p: PLL) void {
    mmio.unsetMask(dpllCtlReg(p), DPLL_CTL_PLL_ENABLE);
}

pub fn allOff() void {
    for (Configurable) |p| dpllOff(p);
}

pub fn pllRegValue(p: PLL) u32 {
    return registerValue(p);
}
