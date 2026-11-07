// koru/native i915/pipe — Primary pipe plane + display setup,
// ported from libgfxinit common/hw-gfx-gma-pipe_setup.adb/.ads
// (coreboot, GPL-2.0), reduced to Pipe A, Plane 1, Linear tiling,
// no rotation, no scaling, Has_Plane_Control=true path.

const mmio = @import("mmio.zig");
const R = mmio.R;
const dp = @import("dp.zig");
const transcoder = @import("transcoder.zig");
const types = @import("types.zig");

// ---- constants (pipe_setup.adb) ----------------------------------------------
const PLANE_CTL_ENABLE: u32 = 1 << 31;
// SKL DSPCNTR: format field is bits 27:24 (Linux
// PLANE_CTL_FORMAT_MASK_SKL=GENMASK(27,24)); XRGB8888=4 -> 4<<24.
// libgfxinit's 6<<26 is a FIXME hardcode on a different field layout —
// it decoded as a 16bpp format and produced the pink-fringe garble.
const DSPCNTR_FORMAT: u32 = 4 << 24;
const DSPCNTR_MASK: u32 = PLANE_CTL_ENABLE | (0xF << 24) |
    (1 << 14) | (1 << 10);

const PLANE_WM_ENABLE: u32 = 1 << 31;
const PLANE_WM_LINES_SHIFT: u6 = 14;
fn planeWmLines(lines: u32) u32 {
    return (lines << PLANE_WM_LINES_SHIFT) & (0x1f << 14);
}
fn planeWmBlocks(blocks: u32) u32 {
    return blocks & 0x3ff; // Has_Wide_Watermarks=false
}

const PIPESRC = R.PIPEASRC;
const PIPEMISC = R.PIPEAMISC;

fn encodeSize(lsw: u32, msw: u32) u32 {
    return ((msw - 1) << 16) | (lsw - 1);
}

// BPC_Conf for PIPEMISC: Has_Pipeconf_BPC=true -> BPC bits + dither.
fn bpcConf(bpc: u64, dither: bool) u32 {
    const bpcBits: u32 = switch (bpc) {
        6 => 2 << 5, 8 => 0, 10 => 1 << 5, 12 => 3 << 5, else => 0,
    };
    return bpcBits | (if (dither) @as(u32, 1) << 4 else 0);
}

// Pixel_To_Bytes: stride(px) * bpc / 2 — raw bytes for DSPSTRIDE.
fn pixelToBytes(pixels: u64, fb: *const types.Framebuffer) u64 {
    return pixels * fb.bpc / 2;
}

// Setup_Watermarks (Primary): BUF_CFG + WM level 0 for planes 1/2/cur.
fn setupWatermarks() void {
    const enc = struct {
        fn f(start: u32, count: u32) u32 {
            return ((start + count - 1) << 16) | start;
        }
    };
    mmio.wr(R.PLANE_BUF_CFG_1_A, enc.f(0, 150));
    mmio.wr(R.PLANE_WM_1_A_0, PLANE_WM_ENABLE | planeWmLines(2) | planeWmBlocks(150));
    mmio.wr(R.PLANE_BUF_CFG_2_A, enc.f(150, 11));
    mmio.wr(R.PLANE_WM_2_A_0, PLANE_WM_ENABLE | planeWmLines(2) | planeWmBlocks(11));
    mmio.wr(R.CUR_BUF_CFG_A, enc.f(161, 8));
    mmio.wr(R.CUR_WM_A_0, PLANE_WM_ENABLE | planeWmLines(2) | planeWmBlocks(8));
}

// Setup_Hires_Plane (Linear, no rotation, DSPCNTR branch): libgfxinit
// order — control WITHOUT enable, stride/linoff/tileoff/surf, geometry,
// then enable. SKL self-arms plane regs on the enable transition.
fn setupHiresPlane(fb: *const types.Framebuffer) void {
    mmio.wr(R.PLANE_AUX_DIST_1_A, 0);
    mmio.unsetAndSet(R.DSPACNTR, DSPCNTR_MASK, DSPCNTR_FORMAT); // no enable
    const strideB = pixelToBytes(fb.stride, fb);
    mmio.say("i915: plane stride="); mmio.sayDec(strideB); mmio.say("B fmt=XRGB8888\n");
    mmio.wr(R.DSPASTRIDE, @intCast(strideB));
    mmio.wr(R.DSPALINOFF, 0);  // Has_DSP_Linoff + Linear: linoff = bytes(0,0)
    mmio.wr(R.DSPATILEOFF, 0); // Linear: tileoff = 0 (was StartY<<16|StartX)
    mmio.wr(R.PLANE_SIZE_1_A, encodeSize(fb.width, fb.height));
    mmio.wr(R.PLANE_POS_1_A, 0);
    mmio.wr(R.DSPASURF, @as(u32, @intCast(fb.offset)) & ~@as(u32, 0xfff));
    mmio.wr(R.DSPACNTR, PLANE_CTL_ENABLE | DSPCNTR_FORMAT);
}

// Panel_Fitter_Off (Has_Plane_Control): disable scaler on pipe A.
fn panelFitterOff() void {
    mmio.unsetMask(R.PS_CTRL_1_A, 1 << 31); // PS_CTRL_ENABLE_SCALER
    mmio.wr(R.PS_WIN_SZ_1_A, 0);
    mmio.unsetMask(R.PS_CTRL_2_A, 1 << 31);
    mmio.wr(R.PS_WIN_SZ_2_A, 0);
}

// Cursor off: CUR_CTL_A = 0 (No_Cursor, pipe select 0 for Primary).
fn cursorOff() void {
    mmio.wr(R.CUR_CTL_A, 0);
}

// Setup_Display: watermarks + PIPESRC + PIPEMISC (misc path taken since
// Has_Pipeconf_Misc=true).
fn setupDisplay(fb: *const types.Framebuffer, mode: *const dp.Mode, dither: bool) void {
    setupWatermarks();
    mmio.wr(PIPESRC, encodeSize(fb.height, fb.width));
    const misc: u32 = bpcConf(mode.bpc, dither) |
        (1 << 8) | // PIPEMISC_PIXEL_ROUNDING_TRUNC
        (1 << 23); // PIPEMISC_HDR_MODE_PRECISION
    mmio.wr(PIPEMISC, misc);
}

// Pipe_Setup.On for Primary + Trans_EDP (fb non-VGA path).
pub fn on(fb: *const types.Framebuffer, mode: *const dp.Mode, link: *const dp.DPLink) void {
    mmio.say("i915: pipe=A plane=1(hires) transcoder=EDP\n");
    transcoder.setup(mode.*, link.*);
    cursorOff(); // Update_Cursor(Default_Cursor)
    setupDisplay(fb, mode, fb.bpc != mode.bpc);
    setupHiresPlane(fb);
    panelFitterOff();
    cursorOff(); // Update_Cursor(Pipe_Cfg.Cursor) — default off
    transcoder.on(mode.*, link.*);
}
