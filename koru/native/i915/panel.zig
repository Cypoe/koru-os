// koru/native i915/panel — eDP panel power sequencer + backlight,
// ported from libgfxinit common/hw-gfx-gma-panel.adb (coreboot, GPL-2.0),
// reduced to Panel_1=eDP, Has_PCH_Panel_Power=true.
//
// Resolved config for Gen=Skylake/PCH=Sunrise_Point:
//   Has_PP_Divisor_Reg = not Broxton and not Cannon_Point_On = FALSE
//     -> power-cycle delay lives in PP_CONTROL bits [8:4] (BXT encoding).
//   Has_PP_Port_Select / Has_PP_Write_Protection = Up_To_Ironlake = FALSE.
//   Has_New_Backlight_Control = TRUE (BXT_BLC_PWM_CTL_1 enable bit).
//   Use_PP_VDD_Override = FALSE -> Panel.On drives TARGET_ON directly.
//   EDP_AUX_Backlight = FALSE -> backlight via PP_CONTROL bit2.
//   Default delays (us): up=210000, up->bl=100 (forced by PRM), down=500000,
//   bl_off->down=50000, cycle=510000.

const mmio = @import("mmio.zig");
const R = mmio.R;

// PP reg set for Panel_1 (Has_PCH_Panel_Power -> PCH_PP_*)
const PP_STATUS = R.PCH_PP_STATUS;
const PP_CONTROL = R.PCH_PP_CONTROL;
const PP_ON_DELAYS = R.PCH_PP_ON_DELAYS;
const PP_OFF_DELAYS = R.PCH_PP_OFF_DELAYS;
const PP_DIVISOR = R.PCH_PP_DIVISOR; // unused (Has_PP_Divisor_Reg=false)

const STATUS_ENABLED: u32 = 1 << 31;
const STATUS_PWR_SEQ_MASK: u32 = 3 << 28;
const STATUS_PWR_SEQ_NONE: u32 = 0 << 28;
const STATUS_CYC_DELAY_ACTIVE: u32 = 1 << 27;

const CONTROL_WRITE_PROT_MASK: u32 = 0xffff << 16;
const CONTROL_WRITE_PROT_KEY: u32 = 0xabcd << 16;
const CONTROL_VDD_OVERRIDE: u32 = 1 << 3;
const CONTROL_BACKLIGHT_ENABLE: u32 = 1 << 2;
const CONTROL_POWER_DOWN_ON_RESET: u32 = 1 << 1;
const CONTROL_TARGET_ON: u32 = 1 << 0;

// BXT power-cycle delay in PP_CONTROL bits [8:4], unit 100ms
const BXT_PWR_CYC_DELAY_SHIFT: u6 = 4;
const BXT_PWR_CYC_DELAY_MASK: u32 = 0x1f << 4;
fn bxtPwrCycDelay(us: u64) u32 {
    return (@as(u32, @intCast((us + 100_000 - 1) / 100_000)) + 1) << BXT_PWR_CYC_DELAY_SHIFT;
}

const ON_DELAYS_PORT_MASK: u32 = 3 << 30;
const ON_DELAYS_PWR_UP_MASK: u32 = 0x1fff << 16;
const ON_DELAYS_PWR_UP_BL_MASK: u32 = 0x1fff;
fn onDelaysPwrUp(us: u64) u32 {
    return @as(u32, @intCast((us + 99) / 100)) << 16;
}
fn onDelaysPwrUpBl(us: u64) u32 {
    return @as(u32, @intCast((us + 99) / 100));
}

const OFF_DELAYS_PWR_DOWN_MASK: u32 = 0x1fff << 16;
const OFF_DELAYS_BL_OFF_PWR_DOWN_MASK: u32 = 0x1fff;
fn offDelaysPwrDown(us: u64) u32 {
    return @as(u32, @intCast((us + 99) / 100)) << 16;
}
fn offDelaysBlOffPwrDown(us: u64) u32 {
    return @as(u32, @intCast((us + 99) / 100));
}

const BLC_PWM_CTL_ENABLE: u32 = 1 << 31; // BXT_BLC_PWM_CTL_1
const BLC_PWM_CTL: u32 = R.BXT_BLC_PWM_CTL_1;

// delays in us
const D_PWR_UP: usize = 0;
const D_UP_TO_BL: usize = 1;
const D_PWR_DOWN: usize = 2;
const D_BL_OFF_TO_DOWN: usize = 3;
const D_PWR_CYCLE: usize = 4;
const DEFAULT_DELAYS = [5]u64{ 210_000, 50_000, 500_000, 50_000, 510_000 };
var delaysUs = DEFAULT_DELAYS;

// timers in us (monotonic)
var powerCycleTimer: u64 = 0;
var powerUpTimer: u64 = 0;

fn nowUs() u64 {
    return mmio.nowMs() * 1000;
}
fn delayUntil(t: u64) void {
    mmio.sleepUs(t -| nowUs());
}

pub fn staticInit() void {
    powerCycleTimer = nowUs();
    powerUpTimer = powerCycleTimer;
    delaysUs = DEFAULT_DELAYS;
}

fn divRoundUp32(num: u64, denom: u64) u32 {
    return @intCast((num + denom - 1) / denom);
}

// Setup_PP_Sequencer(Default_Delays=false): read BIOS-programmed
// delays, default any zero field, write back our values.
pub fn setupPPSequencer(defaultDelays: bool) void {
    var overrideDelays = defaultDelays;
    if (!defaultDelays) {
        const onDelay = mmio.rd(PP_ON_DELAYS);
        delaysUs[D_PWR_UP] = 100 * @as(u64, (onDelay & ON_DELAYS_PWR_UP_MASK) >> 16);
        delaysUs[D_UP_TO_BL] = 100 * @as(u64, onDelay & ON_DELAYS_PWR_UP_BL_MASK);
        const offDelay = mmio.rd(PP_OFF_DELAYS);
        delaysUs[D_PWR_DOWN] = 100 * @as(u64, (offDelay & OFF_DELAYS_PWR_DOWN_MASK) >> 16);
        delaysUs[D_BL_OFF_TO_DOWN] = 100 * @as(u64, offDelay & OFF_DELAYS_BL_OFF_PWR_DOWN_MASK);
        // Has_PP_Divisor_Reg=false -> cycle delay from CONTROL bits[8:4]
        const ctl = mmio.rd(PP_CONTROL);
        const cyc = ctl & BXT_PWR_CYC_DELAY_MASK;
        if ((cyc >> BXT_PWR_CYC_DELAY_SHIFT) > 1) {
            delaysUs[D_PWR_CYCLE] = 100_000 * (@as(u64, cyc >> BXT_PWR_CYC_DELAY_SHIFT) - 1);
        }
        // Check_PP_Delays: any zero -> default + override
        for (0..5) |d| {
            if (delaysUs[d] == 0) {
                delaysUs[d] = DEFAULT_DELAYS[d];
                overrideDelays = true;
            }
        }
    }

    if (overrideDelays) {
        // Port_Select=0 (Has_PP_Port_Select=false); PRM wants up->bl = 100us.
        mmio.unsetAndSet(PP_ON_DELAYS,
            ON_DELAYS_PORT_MASK | ON_DELAYS_PWR_UP_MASK | ON_DELAYS_PWR_UP_BL_MASK,
            onDelaysPwrUp(delaysUs[D_PWR_UP]) | onDelaysPwrUpBl(100));
        mmio.unsetAndSet(PP_OFF_DELAYS,
            OFF_DELAYS_PWR_DOWN_MASK | OFF_DELAYS_BL_OFF_PWR_DOWN_MASK,
            offDelaysPwrDown(delaysUs[D_PWR_DOWN]) |
            offDelaysBlOffPwrDown(delaysUs[D_BL_OFF_TO_DOWN]));
        // Has_PP_Divisor_Reg=false -> write cycle delay into CONTROL[8:4]
        mmio.unsetAndSet(PP_CONTROL,
            BXT_PWR_CYC_DELAY_MASK,
            bxtPwrCycDelay(delaysUs[D_PWR_CYCLE]));
    }

    // Has_PP_Write_Protection=false -> just set power-down-on-reset.
    mmio.setMask(PP_CONTROL, CONTROL_POWER_DOWN_ON_RESET);
    _ = PP_DIVISOR;
    _ = STATUS_CYC_DELAY_ACTIVE;
    _ = CONTROL_WRITE_PROT_MASK;
    _ = CONTROL_WRITE_PROT_KEY;
}

fn waitOn(vddOnly: bool) void {
    _ = vddOnly; // Use_PP_VDD_Override=false -> VDD_Only path never taken
    delayUntil(powerUpTimer);
    const ok = mmio.wait(PP_STATUS,
        STATUS_ENABLED | STATUS_PWR_SEQ_MASK,
        STATUS_ENABLED | STATUS_PWR_SEQ_NONE, 1000);
    if (!ok) mmio.say("i915: panel power sequencer timeout\n");
    if (ok) mmio.unsetMask(PP_CONTROL, CONTROL_VDD_OVERRIDE);
}

pub fn on() void {
    const ctl = mmio.rd(PP_CONTROL);
    const wasOn = (ctl & CONTROL_TARGET_ON) != 0;
    const vddWasOn = (ctl & CONTROL_VDD_OVERRIDE) != 0;
    if (!wasOn) delayUntil(powerCycleTimer);
    mmio.setMask(PP_CONTROL, CONTROL_TARGET_ON);
    if (!wasOn and !vddWasOn) {
        powerUpTimer = nowUs() + delaysUs[D_PWR_UP];
    }
    waitOn(false);
}

pub fn off() void {
    const ctl = mmio.rd(PP_CONTROL);
    const wasOn = (ctl & CONTROL_TARGET_ON) != 0;
    const vddWasOn = (ctl & CONTROL_VDD_OVERRIDE) != 0;
    mmio.unsetMask(PP_CONTROL, CONTROL_TARGET_ON | CONTROL_VDD_OVERRIDE);
    if (wasOn) mmio.sleepUs(delaysUs[D_PWR_DOWN]);
    _ = mmio.waitUnset(PP_STATUS, STATUS_PWR_SEQ_MASK, 600);
    if (wasOn or vddWasOn) {
        powerCycleTimer = nowUs() + delaysUs[D_PWR_CYCLE];
    }
}

pub fn backlightOn() void {
    // Has_New_Backlight_Control -> BXT PWM enable, then PP BL enable.
    mmio.setMask(BLC_PWM_CTL, BLC_PWM_CTL_ENABLE);
    mmio.setMask(PP_CONTROL, CONTROL_BACKLIGHT_ENABLE);
}
pub fn backlightOff() void {
    mmio.unsetMask(PP_CONTROL, CONTROL_BACKLIGHT_ENABLE);
    mmio.unsetMask(BLC_PWM_CTL, BLC_PWM_CTL_ENABLE);
}

// VDD_Override: only meaningful with Use_PP_VDD_Override (false for SKL);
// kept for interface parity — falls through to On().
pub fn vddOverride() void {
    on();
}
