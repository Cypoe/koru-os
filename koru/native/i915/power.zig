// koru/native i915/power — power wells + CDCLK, ported from
// libgfxinit common/skylake/hw-gfx-gma-power_and_clocks.adb (coreboot,
// GPL-2.0), reduced to Gen=Skylake / PCH=Sunrise_Point / eDP-on-DIGI_A.
//
// Power domains on SKL: PW1/PW2 are the display power wells, DDI_A..E are
// per-port wells, MISC_IO the always-on domain. eDP needs DDI_AE (the
// combined well covering DIGI_A); PW2 only when non-eDP pipes exist.

const mmio = @import("mmio.zig");
const R = mmio.R;
const pcode = @import("pcode.zig");

// ---- power-domain bit positions (PWR_WELL_CTL_*) -------------------------
const PD_MISC_IO: u32 = 0;
const PD_DDI_AE: u32 = 1;
const PD_DDI_B: u32 = 2;
const PD_DDI_C: u32 = 3;
const PD_DDI_D: u32 = 4;
const PD_PW1: u32 = 5;
const PD_PW2: u32 = 6;

fn reqBit(pd: u32) u32 {
    return switch (pd) {
        PD_MISC_IO => 1 << 1,
        PD_DDI_AE => 1 << 3,
        PD_DDI_B => 1 << 5,
        PD_DDI_C => 1 << 7,
        PD_DDI_D => 1 << 9,
        PD_PW1 => 1 << 29,
        PD_PW2 => 1 << 31,
        else => 0,
    };
}
fn stateBit(pd: u32) u32 {
    return switch (pd) {
        PD_MISC_IO => 1 << 0,
        PD_DDI_AE => 1 << 2,
        PD_DDI_B => 1 << 4,
        PD_DDI_C => 1 << 6,
        PD_DDI_D => 1 << 8,
        PD_PW1 => 1 << 28,
        PD_PW2 => 1 << 30,
        else => 0,
    };
}
// FUSE_STATUS PGx dist-status, indexed by Power_Well (PW1=bit26, PW2=bit25)
fn fuseDistBit(pd: u32) u32 {
    return switch (pd) {
        PD_PW1 => 1 << 26,
        PD_PW2 => 1 << 25,
        else => 0,
    };
}

const NDE_RSTWRN_OPT_RST_PCH_Handshake_En: u32 = 1 << 4;
const FUSE_STATUS_DOWNLOAD_STATUS: u32 = 1 << 31;
const FUSE_STATUS_PG0_DIST_STATUS: u32 = 1 << 27;

const DBUF_CTL_DBUF_POWER_REQUEST: u32 = 1 << 31;
const DBUF_CTL_DBUF_POWER_STATE: u32 = 1 << 30;

const LCPLL1_CTL_PLL_ENABLE: u32 = 1 << 31;
const LCPLL1_CTL_PLL_LOCK: u32 = 1 << 30;
const DISP_FBC_MEMORY_WAKE: u32 = 1 << 31;

// ---- CDCLK ----------------------------------------------------------------
const CDCLK_CTL_CD_FREQ_SELECT_MASK: u32 = 3 << 26;
const CDCLK_CTL_CD_FREQ_SELECT_450MHZ: u32 = 0 << 26;
const CDCLK_CTL_CD_FREQ_SELECT_540MHZ: u32 = 1 << 26;
const CDCLK_CTL_CD_FREQ_SELECT_337_5MHZ: u32 = 2 << 26;
const CDCLK_CTL_CD_FREQ_SELECT_675MHZ: u32 = 3 << 26;
const CDCLK_CTL_CD_FREQ_DECIMAL_MASK: u32 = 0x7ff;

const SKL_PCODE_CDCLK_CONTROL: u64 = 7;
const SKL_CDCLK_PREPARE_FOR_CHANGE: u64 = 3;
const SKL_CDCLK_READY_FOR_CHANGE: u64 = 1;

fn cdFreqDecimal(freq: u64) u32 {
    // CDClk - 1MHz in 10.1 (10 + 1 fractional bit)
    return @intCast((freq - 1_000_000) / 500_000);
}

pub const CdClk337 = 337_500_000;
pub const CdClk450 = 450_000_000;
pub const CdClk540 = 540_000_000;
pub const CdClk675 = 675_000_000;

fn normalizeCdClk(freq: u64) u64 {
    if (freq <= 337_500_000) return CdClk337;
    if (freq <= 450_000_000) return CdClk450;
    if (freq <= 540_000_000) return CdClk540;
    return CdClk675;
}

var cdclk: u64 = CdClk337;
var maxCdclk: u64 = CdClk337;
pub fn getCdClk() u64 {
    return cdclk;
}
pub fn getMaxCdClk() u64 {
    return maxCdclk;
}

fn getCurCdClk() void {
    const ctl = mmio.rd(R.CDCLK_CTL) & CDCLK_CTL_CD_FREQ_DECIMAL_MASK;
    cdclk = normalizeCdClk(@as(u64, ctl) * 500_000 + 1_000_000);
}

// DFSM decode per Ada Get_Max_CDClk: DFSM_DISPLAY_CDCLK_LIMIT_{675,540,
// 450}MHZ = {0,1,2}<<23; anything else (3<<23) -> 337.5MHz.
fn decodeDfsmLimit(dfsm: u32) u64 {
    return switch (dfsm & (3 << 23)) {
        0 => CdClk675,
        1 << 23 => CdClk540,
        2 << 23 => CdClk450,
        else => CdClk337,
    };
}

fn setCdClk(cdclkIn: u64) bool {
    const target = normalizeCdClk(@min(cdclkIn, maxCdclk));
    const ok = pcode.mailboxRequest(
        SKL_PCODE_CDCLK_CONTROL,
        SKL_CDCLK_PREPARE_FOR_CHANGE,
        SKL_CDCLK_READY_FOR_CHANGE,
        SKL_CDCLK_READY_FOR_CHANGE,
        mmio.DefaultTimeoutMs,
        true,
    );
    if (!ok) {
        mmio.say("i915: pcode not ready for cdclk change\n");
        return false;
    }
    const sel: u32 = switch (target) {
        CdClk675 => CDCLK_CTL_CD_FREQ_SELECT_675MHZ,
        CdClk540 => CDCLK_CTL_CD_FREQ_SELECT_540MHZ,
        CdClk450 => CDCLK_CTL_CD_FREQ_SELECT_450MHZ,
        else => CDCLK_CTL_CD_FREQ_SELECT_337_5MHZ,
    };
    mmio.wr(R.CDCLK_CTL, sel | cdFreqDecimal(target));
    _ = pcode.mailboxWrite(
        SKL_PCODE_CDCLK_CONTROL,
        switch (target) {
            CdClk675 => 3,
            CdClk540 => 2,
            CdClk450 => 1,
            else => 0,
        },
        false,
    );
    mmio.setMask(R.DBUF_CTL_S0, DBUF_CTL_DBUF_POWER_REQUEST);
    if (!mmio.waitSet(R.DBUF_CTL_S0, DBUF_CTL_DBUF_POWER_STATE, mmio.DefaultTimeoutMs)) {
        mmio.say("i915: dbuf power state timeout\n");
        return false;
    }
    cdclk = target;
    return true;
}

// ---- power domains ---------------------------------------------------------

fn pdOff(pd: u32) void {
    const c1 = mmio.rd(R.PWR_WELL_CTL_BIOS);
    const c2 = mmio.rd(R.PWR_WELL_CTL_DRIVER);
    const c3 = mmio.rd(R.PWR_WELL_CTL_KVMR);
    const c4 = mmio.rd(R.PWR_WELL_CTL_DEBUG);
    mmio.postingRead(R.PWR_WELL_CTL5);
    mmio.postingRead(R.PWR_WELL_CTL6);

    const anyReq = (c1 | c2 | c3 | c4) & reqBit(pd);
    if (anyReq != 0) {
        _ = mmio.waitSet(R.PWR_WELL_CTL_DRIVER, stateBit(pd), 100);
    }
    if ((c1 & reqBit(pd)) != 0) mmio.unsetMask(R.PWR_WELL_CTL_BIOS, reqBit(pd));
    if ((c2 & reqBit(pd)) != 0) mmio.unsetMask(R.PWR_WELL_CTL_DRIVER, reqBit(pd));
}

fn pdOn(pd: u32) bool {
    const c1 = mmio.rd(R.PWR_WELL_CTL_BIOS);
    const c2 = mmio.rd(R.PWR_WELL_CTL_DRIVER);
    const c3 = mmio.rd(R.PWR_WELL_CTL_KVMR);
    const c4 = mmio.rd(R.PWR_WELL_CTL_DEBUG);
    mmio.postingRead(R.PWR_WELL_CTL5);
    mmio.postingRead(R.PWR_WELL_CTL6);

    if (((c1 | c2 | c3 | c4) & reqBit(pd)) == 0) {
        if (!mmio.waitUnset(R.PWR_WELL_CTL_DRIVER, stateBit(pd), 100))
            return false;
    }
    if ((c2 & reqBit(pd)) == 0) {
        mmio.setMask(R.PWR_WELL_CTL_DRIVER, reqBit(pd));
        if (!mmio.waitSet(R.PWR_WELL_CTL_DRIVER, stateBit(pd), 100))
            return false;
        if (pd == PD_PW1 or pd == PD_PW2) {
            if (!mmio.waitSet(R.FUSE_STATUS, fuseDistBit(pd), 100))
                return false;
        }
    }
    return true;
}

// ---- init ------------------------------------------------------------------

pub fn initialize() bool {
    mmio.setMask(R.NDE_RSTWRN_OPT, NDE_RSTWRN_OPT_RST_PCH_Handshake_En);
    if (!mmio.waitSet(R.FUSE_STATUS, FUSE_STATUS_PG0_DIST_STATUS, 100)) {
        mmio.say("i915: PG0 dist status timeout\n");
        return false;
    }
    if (!pdOn(PD_PW1)) { mmio.say("i915: PW1 on failed\n"); return false; }
    if (!pdOn(PD_MISC_IO)) { mmio.say("i915: MISC_IO on failed\n"); return false; }

    // LCPLL1: the display core PLL — enable + wait lock.
    mmio.setMask(R.LCPLL1_CTL, LCPLL1_CTL_PLL_ENABLE);
    if (!mmio.waitSet(R.LCPLL1_CTL, LCPLL1_CTL_PLL_LOCK, 100)) {
        mmio.say("i915: LCPLL1 lock timeout\n");
        return false;
    }

    // WaEnableChickenDCPR:skl,bxt,kbl,glk,cfl — bit13 of GEN8_CHICKEN_DCPR_1
    mmio.setMask(R.GEN8_CHICKEN_DCPR_1, 1 << 13);
    // Display WA #0859 WaFbcWakeMemOn
    mmio.setMask(R.ARB_CTL, DISP_FBC_MEMORY_WAKE);

    getCurCdClk();
    maxCdclk = decodeDfsmLimit(mmio.rd(R.DFSM));
    if (!setCdClk(337_500_000)) return false;

    mmio.say("i915: power init done, cdclk=");
    mmio.sayDec(cdclk);
    mmio.say(" max=");
    mmio.sayDec(maxCdclk);
    mmio.say("\n");
    return true;
}

// Power_Up(eDP) -> PD_On(DDI_AE). Called per-port before connector prep.
pub fn powerUpEdp() bool {
    return pdOn(PD_DDI_AE);
}

// Limit_Dotclocks: dotclock must not exceed CDCLK; returns whether a
// CDCLK switch is needed. For M0 single pipe at 148.5MHz dotclock and
// 337.5MHz CDCLK, never triggers — kept for fidelity.
pub fn limitDotclocks(dotclock: u64) bool {
    const capped = @min(dotclock, maxCdclk);
    return cdclk != normalizeCdClk(capped);
}

// Update_CDClk: raise CDCLK to fit the highest dotclock.
pub fn updateCdClk(dotclock: u64) bool {
    if (!setCdClk(@min(dotclock, 675_000_000))) return false;
    return true;
}

// Raw clock: SKL has fractional rawclk (Cannon_Point_On). SFUSE_STRAP
// bit8 set -> 24MHz, clear -> 19.2MHz. Default_RawClk_Freq=24MHz.
pub fn getRawClock() u64 {
    const f24 = mmio.isSet(R.SFUSE_STRAP, 1 << 8);
    if (f24) return 24_000_000;
    return 19_200_000;
}
