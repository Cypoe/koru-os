// koru/native i915/connector_info — link-setting selection,
// ported from libgfxinit common/hw-gfx-gma-connector_info.adb
// (coreboot, GPL-2.0), reduced to eDP-on-DP_A path.
//
// For eDP: Panel.On -> Switch_LSPCON (no-op, no Type-C) ->
// DP_Info.Read_Caps (AUX DPCD) -> Read_eDP_Rates ->
// Preferred_Link_Setting -> sink power wake (DPCD 0x600) ->
// MST-capable check (DPCD 0x21; eDP panels aren't MST -> skipped).

const mmio = @import("mmio.zig");
const dp = @import("dp.zig");
const panel = @import("panel.zig");

pub const AuxPayload = [16]u8;

// Preferred_Link_Setting for Display=DP (eDP counts): power the panel,
// read receiver caps + eDP rates over AUX, pick link rate/lanes for Mode.
pub fn preferredLinkSetting(mode: dp.Mode, link: *dp.DPLink) bool {
    panel.on(); // Use_PP_VDD_Override=false for SKL -> Panel.On
    // DP_Dual_Mode.Switch_LSPCON(DP_A): no Type-C on SKL -> no-op

    if (!dp.readCaps(link)) return false;
    dp.readEdpRates(link);
    if (!dp.preferredLinkSetting(link, mode)) return false;

    // Wake DP sinks out of power-save (DPCD 0x600 = SINK_CONTROL, D0 bit)
    if (link.rx.rev >= 0x11) {
        var woken = false;
        var try_: u32 = 0;
        while (try_ < 3) : (try_ += 1) {
            const d0: AuxPayload = blk: {
                var d: AuxPayload = @splat(0);
                d[0] = 1;
                break :blk d;
            };
            woken = dp.auxWrite(dp.DP_A, 0x600, d0[0..1]);
            if (woken) break;
            mmio.sleepMs(1);
        }
    }

    // MST branch check: only SST supported. eDP sinks report
    // MSTM_CAP=0 so this normally skips; ported for fidelity.
    if (link.rx.rev >= 0x12) {
        var data: AuxPayload = @splat(0);
        if (dp.auxRead(dp.DP_A, 0x21, data[0..1]) and (data[0] & 1) != 0) {
            var sst: AuxPayload = @splat(0);
            _ = dp.auxWrite(dp.DP_A, 0x111, sst[0..1]); // MSTM_CTRL = SST
        }
    }
    return true;
}

// Next_Link_Setting: try the next (slower) link config on failure.
pub fn nextLinkSetting(link: *dp.DPLink, mode: dp.Mode) bool {
    return dp.nextLinkSetting(link, mode);
}

// Default_BPC: eDP on DIGI_A with Display=DP (not HDMI) -> 6.
pub fn defaultBpc() u64 {
    return 6;
}
