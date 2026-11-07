// koru/native i915/transcoder — Trans_EDP transcoder + pipe timing,
// ported from libgfxinit common/hw-gfx-gma-transcoder.adb/.ads
// (coreboot, GPL-2.0). Only the Trans_EDP index is used: eDP on DIGI_A
// maps there via Get_Idx (Has_EDP_Transcoder=true, Has_Tertiary_Pipe n/a).

const mmio = @import("mmio.zig");
const R = mmio.R;
const dp = @import("dp.zig");

// Trans_EDP register set (transcoder.ads).
const HTOTAL = R.HTOTAL_EDP;
const HBLANK = R.HBLANK_EDP;
const HSYNC = R.HSYNC_EDP;
const VTOTAL = R.VTOTAL_EDP;
const VBLANK = R.VBLANK_EDP;
const VSYNC = R.VSYNC_EDP;
const CONF = R.PIPE_EDP_CONF;
const DATA_M1 = R.PIPE_EDP_DATA_M1;
const DATA_N1 = R.PIPE_EDP_DATA_N1;
const LINK_M1 = R.PIPE_EDP_LINK_M1;
const LINK_N1 = R.PIPE_EDP_LINK_N1;
const DDI_FUNC_CTL = R.PIPE_EDP_DDI_FUNC_CTL;
const MSA_MISC = R.PIPE_EDP_MSA_MISC;

const CONF_ENABLE: u32 = 1 << 31;
const FUNC_ENABLE: u32 = 1 << 31;
const FUNC_MODE_DP_SST: u32 = 2 << 24;
const FUNC_BPC_6: u32 = 2 << 20;
const FUNC_BPC_8: u32 = 0 << 20;
const FUNC_BPC_10: u32 = 1 << 20;
const FUNC_BPC_12: u32 = 3 << 20;
fn funcBpc(bpc: u64) u32 {
    return switch (bpc) {
        6 => FUNC_BPC_6, 8 => FUNC_BPC_8, 10 => FUNC_BPC_10, 12 => FUNC_BPC_12,
        else => FUNC_BPC_8,
    };
}
fn funcPortWidth(l: dp.LaneCount) u32 {
    return switch (l) { .l1 => 0, .l2 => 1 << 1, .l4 => 3 << 1 };
}
// EDP_SELECT: Primary + !Use_PDW_For_EDP_Scaling -> ALWAYS_ON (0).
const MSA_SYNC_CLK: u32 = 1;
fn msaBpc(bpc: u64) u32 {
    return switch (bpc) {
        6 => 0 << 5, 8 => 1 << 5, 10 => 2 << 5, 12 => 3 << 5, 16 => 4 << 5,
        else => 1 << 5,
    };
}

fn encode(lsw: u32, msw: u32) u32 {
    return ((msw - 1) << 16) | (lsw - 1);
}

// Setup_Link: DP_Info.Calculate_M_N then write M/N regs.
fn setupLink(link: dp.DPLink, mode: dp.Mode) void {
    const mn = dp.calculateMN(link, mode);
    mmio.wr(DATA_M1, (@as(u32, 63) << 25) | @as(u32, @intCast(mn.dm))); // TRANS_DATA_M_TU(64)
    mmio.wr(DATA_N1, @as(u32, @intCast(mn.dn)));
    mmio.wr(LINK_M1, @as(u32, @intCast(mn.lm)));
    mmio.wr(LINK_N1, @as(u32, @intCast(mn.ln)));
    mmio.wr(MSA_MISC, MSA_SYNC_CLK | msaBpc(mode.bpc));
}

// Setup: timings + link M/N. (CLK_SEL invalid for Trans_EDP -> skipped.)
pub fn setup(mode: dp.Mode, link: dp.DPLink) void {
    setupLink(link, mode);
    mmio.wr(HTOTAL, encode(mode.hVisible, mode.hTotal));
    mmio.wr(HBLANK, encode(mode.hVisible, mode.hTotal));
    mmio.wr(HSYNC, encode(mode.hSyncBegin, mode.hSyncEnd));
    mmio.wr(VTOTAL, encode(mode.vVisible, mode.vTotal));
    mmio.wr(VBLANK, encode(mode.vVisible, mode.vTotal));
    mmio.wr(VSYNC, encode(mode.vSyncBegin, mode.vSyncEnd));
}

// Configure + On combined: write DDI_FUNC_CTL then enable transcoder.
// DIGI_A select=0, DP_SST, mode BPC, no sync polarity (1080p60 neg),
// EDP_SELECT always-on, port width from link.
pub fn on(mode: dp.Mode, link: dp.DPLink) void {
    var v: u32 = FUNC_MODE_DP_SST | funcBpc(mode.bpc) |
        funcPortWidth(link.laneCount);
    // DDI_FUNC_CTL_DDI_SELECT(DIGI_A)=0, VSYNC/HSYNC false->0,
    // EDP_SELECT always-on=0 for Primary.
    mmio.wr(DDI_FUNC_CTL, v);
    v = mmio.rd(DDI_FUNC_CTL) | FUNC_ENABLE;
    mmio.wr(DDI_FUNC_CTL, v);
    mmio.wr(CONF, CONF_ENABLE);
    mmio.postingRead(CONF);
}
