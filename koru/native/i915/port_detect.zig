// koru/native i915/port_detect — hotplug/presence detect,
// ported from libgfxinit haswell_shared/hw-gfx-gma-port_detect.adb
// (coreboot, GPL-2.0), reduced to Skylake/KBL + eDP-on-DIGI_A.
//
// Resolved config for Gen=Skylake: Has_HOTPLUG_CTL=Gen_Haswell=FALSE ->
// HPD lives ONLY in SHOTPLUG_CTL (south). Has_PCH_DAC=false -> analog
// block skipped. Has_Presence_Straps=true, Ignore_Presence_Straps=false
// -> eDP validity = DDI_BUF_CTL_A bit0 strap. Has_Hotplug_Invert=false.
// Has_SHOTPLUG_CTL_A=Skylake_On=true.

const mmio = @import("mmio.zig");
const R = mmio.R;

const DETECTED_A: u32 = 1 << 0; // DDI_PORT_DETECTED(DIGI_A) in DDI_BUF_CTL_A

// SHOTPLUG_CTL per-DIGI_A fields (byte 3 of the reg)
const SHOT_INPUT_A: u32 = 1 << 28;
const SHOT_INVERT_A: u32 = 1 << 27;
const SHOT_STATUS_A: u32 = 3 << 24;
const SHOT_LONG_A: u32 = 1 << 25;
const SHOT_DETECT_MASK: u32 = 0x0303_0303;

var validEdp: bool = false;
pub fn edpValid() bool {
    return validEdp;
}

pub fn initialize() void {
    const detected = mmio.isSet(R.DDI_BUF_CTL_A, DETECTED_A);
    if (detected) {
        // Has_HOTPLUG_CTL=false -> SHOTPLUG_CTL gets
        // input-enable | status-clear (invert mask = 0 for SKL).
        mmio.unsetAndSet(R.SHOTPLUG_CTL, SHOT_DETECT_MASK,
            SHOT_INPUT_A | SHOT_STATUS_A);
        _ = SHOT_INVERT_A; // Has_Hotplug_Invert=Gen_Broxton=false -> unused
        _ = SHOT_LONG_A;
    }
    validEdp = detected;
    mmio.say("i915: port_detect eDP strap detected=");
    mmio.say(mmio.ynl(detected));
}

// Hotplug_Detect for DIGI_A via SHOTPLUG_CTL (Has_HOTPLUG_CTL=false).
pub fn hotplugDetect() bool {
    const sctl = mmio.rd(R.SHOTPLUG_CTL);
    const detected = (sctl & SHOT_LONG_A) != 0;
    if ((sctl & SHOT_STATUS_A) != 0) {
        mmio.unsetAndSet(R.SHOTPLUG_CTL, SHOT_DETECT_MASK, SHOT_STATUS_A);
    }
    return detected;
}

// Clear_Hotplug_Detect: consume pending events without reporting.
pub fn clearHotplug() void {
    _ = hotplugDetect();
}
