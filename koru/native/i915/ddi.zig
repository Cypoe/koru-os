// koru/native i915/ddi — DDI buffer/transport control for DIGI_A (eDP),
// ported from libgfxinit haswell_shared/hw-gfx-gma-connectors-ddi.adb
// (coreboot, GPL-2.0) + common/skylake/hw-gfx-gma-connectors-ddi-buffers.adb.
//
// Resolved SKL config: Has_DDI_PHYs=false, Has_Per_DDI_Clock_Sel=false,
// End_EDP_Training_Late=false, Has_DDI_Buffer_Trans=true,
// Use_KBL_DDI_Buf_Trans=true (Kaby Lake table; U/Y variants by CPU_Var).

const mmio = @import("mmio.zig");
const R = mmio.R;
const dp = @import("dp.zig");
const training = @import("training.zig");

// ---- DDI_BUF_CTL_A fields ---------------------------------------------------
const BUF_ENABLE: u32 = 1 << 31;
const TRANS_SELECT_MASK: u32 = 15 << 24;
const PORT_REVERSAL: u32 = 1 << 16;
const IDLE_STATUS: u32 = 1 << 7;
const PORT_WIDTH_MASK: u32 = 7 << 1;
fn portWidth(l: dp.LaneCount) u32 {
    return switch (l) { .l1 => 0, .l2 => 1 << 1, .l4 => 3 << 1 };
}

// VS/Emph -> BUF_TRANS select (0..9)
fn transSelect(vs: u8, emph: u8) u32 {
    return switch (vs) {
        0 => switch (emph) { 0 => 0, 1 => 1, 2 => 2, 3 => 3, else => 0 },
        1 => switch (emph) { 0 => 4, 1 => 5, 2 => 6, else => 0 },
        2 => switch (emph) { 0 => 7, 1 => 8, else => 0 },
        3 => switch (emph) { 0 => 9, else => 0 },
        else => 0,
    };
}

// ---- DP_TP_CTL_A fields -----------------------------------------------------
const TP_TRANSPORT_ENABLE: u32 = 1 << 31;
const TP_ENHANCED: u32 = 1 << 18;
const TP_LINK_TRAIN_MASK: u32 = 7 << 8;
fn tpPatternBits(p: u8) u32 {
    return switch (p) {
        1 => 0 << 8, // PAT1
        2 => 1 << 8, // PAT2
        3 => 4 << 8, // PAT3
        4 => 2 << 8, // IDLE
        else => 3 << 8, // NORMAL (TP_None)
    };
}
const TP_SCRAMBLE_DISABLE: u32 = 1 << 7;

// ---- DPLL_CTRL2 DIGI_A fields ------------------------------------------------
const CLK2_CLOCK_OFF_A: u32 = 1 << 15;
const CLK2_SELECT_MASK_A: u32 = 3 << 1;
const CLK2_SELECT_SHIFT_A: u5 = 1;
const CLK2_SELECT_OVERRIDE_A: u32 = 1 << 0;
// CLOCK_OFF for all digital ports (Post_Reset_Off)
const CLK2_CLOCK_OFF_ALL: u32 = (1 << 15) | (1 << 16) | (1 << 17) | (1 << 18) | (1 << 19);

// ---- CPU variant (set by i915.zig device detect) ------------------------------
pub const CpuVar = enum { desktop, ult, ulx };
pub var cpuVar: CpuVar = .ult; // T590 default guess; detect refines
pub var lastDigitalPort: u8 = 2; // DIGI_C index when Is_LP (A=0,B=1,C=2)
pub var iboost: u32 = 3; // ULT -> 3, else 1

// Max signal levels: Has_DDI_PHYs=false, EDP_Low_Voltage_Swing=false -> VS2.
pub fn maxVSwing() u8 {
    return 2; // VS_Level_2
}
// Max_Pre_Emph per VS: {VS0:E3, VS1:E2, VS2:E1, else:E0}
pub fn maxPreEmph(vs: u8) u8 {
    return switch (vs) {
        0 => 3, 1 => 2, 2 => 1, else => 0,
    };
}

// ---- BUF_TRANS translation tables (ddi-buffers.adb) ---------------------------
// 20 entries = 10 (S,T) pairs for trans_select 0..9. Entries 18,19 = HDMI.
const KBL_DP: [20]u32 = .{
    0x00002016, 0x000000a0, 0x00005012, 0x0000009b, 0x00007011, 0x00000088,
    0x80009010, 0x000000c0, 0x00002016, 0x0000009b, 0x00005012, 0x00000088,
    0x80007011, 0x000000c0, 0x00002016, 0x00000097, 0x80005012, 0x000000c0,
    0x00000018, 0x000000ac, // Skylake_Trans_HDMI(0)
};
const KBL_U_DP: [20]u32 = .{
    0x0000201b, 0x000000a1, 0x00005012, 0x00000088, 0x80007011, 0x000000cd,
    0x80009010, 0x000000c0, 0x0000201b, 0x0000009d, 0x80005012, 0x000000c0,
    0x80007011, 0x000000c0, 0x00002016, 0x0000004f, 0x80005012, 0x000000c0,
    0x00000018, 0x000000ac,
};
const KBL_Y_DP: [20]u32 = .{
    0x00001017, 0x000000a1, 0x00005012, 0x00000088, 0x80007011, 0x000000cd,
    0x8000800f, 0x000000c0, 0x00001017, 0x0000009d, 0x80005012, 0x000000c0,
    0x80007011, 0x000000c0, 0x00001017, 0x0000004c, 0x80005012, 0x000000c0,
    0x00000018, 0xa00000a1 & 0x00ac, // placeholder fixed below
};
// fix Y-table HDMI pair: Skylake_Y_Trans_HDMI(0) = (0x18, 0xa1)
const KBL_Y_DP_FIXED: [20]u32 = blk: {
    var t = KBL_Y_DP;
    t[18] = 0x00000018;
    t[19] = 0x000000a1;
    break :blk t;
};

fn bufTransTable() *const [20]u32 {
    return switch (cpuVar) {
        .ult => &KBL_U_DP,
        .ulx => &KBL_Y_DP_FIXED,
        .desktop => &KBL_DP,
    };
}

// Per-port DDI register triples for BUF_TRANS (S0T1..S9T2 = 20 regs).
// We only need DIGI_A for eDP, but Initialize writes A..Last_Digital_Port.
fn bufTransReg(port: u8, idx: u8) u32 {
    // DIGI_A base + idx*4 — the BUF_TRANS regs are consecutive per port.
    // regs.zig has named symbols; verify names: DDI_BUF_TRANS_A_S0T1 ...
    // Use named lookup table built from R constants.
    const bases = [_]u32{
        R.DDI_BUF_TRANS_A_S0T1, R.DDI_BUF_TRANS_B_S0T1,
        R.DDI_BUF_TRANS_C_S0T1, R.DDI_BUF_TRANS_D_S0T1,
        R.DDI_BUF_TRANS_E_S0T1,
    };
    _ = port;
    return bases[0] + @as(u32, idx) * 4; // DIGI_A only for M0
}

const bufCtlReg = R.DDI_BUF_CTL_A;
const tpCtlReg = R.DP_TP_CTL_A;

pub fn initialize() void {
    // Program_Buffer_Translations for DIGI_A..Last_Digital_Port.
    // For M0 only DIGI_A's table matters for eDP, but write A..C
    // (Is_LP -> Last=DIGI_C) to match hardware state.
    const table = bufTransTable();
    const lastPort: u8 = lastDigitalPort;
    var port: u8 = 0;
    while (port <= lastPort) : (port += 1) {
        var i: usize = 0;
        while (i < 20) : (i += 1) {
            // BUF_TRANS regs are per-port consecutive; for port>0 the
            // register names differ — restrict to DIGI_A for M0 and
            // note B/C tables identical values (same silicon tables).
            if (port == 0) {
                mmio.wr(R.DDI_BUF_TRANS_A_S0T1 + @as(u32, @intCast(i)) * 4, table[i]);
            }
        }
    }
    // DISPIO_CR_TX_BMU_CR0 iboost on all 5 legs.
    const unset: u32 = (0x1f << 23) | (0x07 << 20) | (0x07 << 17) |
        (0x07 << 14) | (0x07 << 11) | (0x07 << 8);
    const set: u32 = (iboost << 20) | (iboost << 17) | (iboost << 14) |
        (iboost << 11) | (iboost << 8);
    mmio.unsetAndSet(R.DISPIO_CR_TX_BMU_CR0, unset, set);
    mmio.say("i915: ddi initialize done (iboost=");
    mmio.sayDec(iboost);
    mmio.say(")\n");
}

pub fn postResetOff() void {
    mmio.setMask(R.DPLL_CTRL2, CLK2_CLOCK_OFF_ALL);
}

// ---- signal levels / training pattern ----------------------------------------

pub fn setSignalLevels(link: dp.DPLink, vs: u8, emph: u8) void {
    const wasEnabled = (mmio.rd(bufCtlReg) & BUF_ENABLE) != 0;
    const sel = transSelect(vs, emph);
    mmio.unsetAndSet(bufCtlReg,
        TRANS_SELECT_MASK | PORT_REVERSAL | PORT_WIDTH_MASK,
        BUF_ENABLE | (sel << 24) | portWidth(link.laneCount));
    mmio.postingRead(bufCtlReg);
    if (!wasEnabled) mmio.sleepUs(600);
}

pub fn setTrainingPattern(link: dp.DPLink, pattern: u8) void {
    // pattern: 1=TP1 2=TP2 3=TP3 4=idle/none
    if (pattern < 4) {
        var v: u32 = TP_TRANSPORT_ENABLE;
        if (link.enhancedFraming) v |= TP_ENHANCED;
        v |= tpPatternBits(pattern);
        if (pattern <= 3) v |= TP_SCRAMBLE_DISABLE; // PAT1-3
        mmio.wr(tpCtlReg, v);
    } else {
        // send at least 5 idle patterns, then normal (DIGI_A: no wait)
        var v: u32 = TP_TRANSPORT_ENABLE;
        if (link.enhancedFraming) v |= TP_ENHANCED;
        v |= tpPatternBits(4); // IDLE
        mmio.wr(tpCtlReg, v);
        v = TP_TRANSPORT_ENABLE;
        if (link.enhancedFraming) v |= TP_ENHANCED;
        v |= tpPatternBits(5); // NORMAL
        mmio.wr(tpCtlReg, v);
    }
}

pub fn digitalOff() void {
    const enabled = (mmio.rd(bufCtlReg) & BUF_ENABLE) != 0;
    if (enabled) mmio.unsetMask(bufCtlReg, BUF_ENABLE);
    mmio.unsetMask(tpCtlReg, TP_TRANSPORT_ENABLE);
    if (enabled) {
        _ = mmio.waitSet(bufCtlReg, IDLE_STATUS, mmio.DefaultTimeoutMs);
    }
    mmio.setMask(R.DPLL_CTRL2, CLK2_CLOCK_OFF_A);
}

// Pre_On: select DPLL clock for DIGI_A then train.
pub fn preOn(link: dp.DPLink, pllHint: u32) bool {
    mmio.unsetAndSet(R.DPLL_CTRL2,
        CLK2_CLOCK_OFF_A | CLK2_SELECT_MASK_A,
        (pllHint << CLK2_SELECT_SHIFT_A) | CLK2_SELECT_OVERRIDE_A);
    if (link.bandwidth == .b1_62 and false) return true; // unreachable guard
    return training.trainDP(link);
}

// Post_On: nothing for eDP on SKL (End_EDP_Training_Late=false, DP display).
pub fn postOn() void {}

pub fn off() void {
    digitalOff();
}
