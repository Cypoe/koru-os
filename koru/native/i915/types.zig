// koru/native i915/types — shared port/mode/framebuffer types,
// distilled from libgfxinit hw-gfx.ads + hw-gfx-gma.ads
// (coreboot, GPL-2.0), reduced to the single-eDP bring-up.

const dp = @import("dp.zig");

pub const GPU_Port = enum(u8) { DIGI_A, DIGI_B, DIGI_C, DIGI_D, DIGI_E };
pub const PCH_Port = enum(u8) { None, DP_B, DP_C, DP_D, LVDS, VGA };
pub const Pipe = enum(u8) { Primary, Secondary, Tertiary };
pub const Display = enum(u8) { VGA, LVDS, DP, HDMI, eDP_Ignore };
// Port_Config.Display values used: DP for eDP (eDP is Display=DP in
// libgfxinit — the eDP-ness lives in the Panel + port), VGA for FDI.

pub const BPC = enum(u8) { bpc_6, bpc_8 };

pub const Mode_Type = dp.Mode;

pub const Framebuffer = struct {
    offset: u64 = 0, // byte offset -> GTT page = offset/4096
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0, // pixels per line
    vstride: u32 = 0, // lines
    bpc: u64 = 8, // bits per color channel (8 -> XRGB8888)
    tiling: enum(u8) { Linear, X, Y } = .Linear,
    compression: bool = false,
    rc_wa: u32 = 0,
};

pub const Port_Config = struct {
    port: GPU_Port = .DIGI_A,
    pch_port: PCH_Port = .None,
    is_fdi: bool = false,
    display: Display = .DP,
    panel: u8 = 0, // Panel_Index; eDP panel = index of CONFIG panel 1
    mode: Mode_Type = undefined,
    dp: dp.DPLink = .{},
    pipe: Pipe = .Primary,
    fb: Framebuffer = .{},
};

pub const Invalid_Mode = Mode_Type{
    .dotclock = 0, .hVisible = 0, .hSyncBegin = 0, .hSyncEnd = 0, .hTotal = 0,
    .vVisible = 0, .vSyncBegin = 0, .vSyncEnd = 0, .vTotal = 0,
    .bpc = 0, .hdmiSink = false,
};
