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
    // SKL _PLANE_STRIDE_1_A (0x70188): 12-bit field [11:0], units of
    // 64-byte chunks for linear (Linux skl_plane_stride_mult=64).
    // libgfxinit's raw Pixel_To_Bytes write overflows the field;
    // correct value is bytes/64 = 120 for 7680B pitch.
    const strideReg = strideB / 64;
    mmio.say("i915: plane stride="); mmio.sayDec(strideB); mmio.say("B reg=");
    mmio.sayDec(strideReg); mmio.say(" fmt=XRGB8888\n");
    const rbBefore = mmio.rd(R.DSPASTRIDE);
    mmio.wr(R.DSPASTRIDE, @intCast(strideReg));
    const rbAfter = mmio.rd(R.DSPASTRIDE);
    mmio.say("  stride[1A] rb before="); mmio.sayHex(rbBefore);
    mmio.say(" after="); mmio.sayHex(rbAfter); mmio.say("\n");
    mmio.wr(R.DSPALINOFF, 0);  // Has_DSP_Linoff + Linear: linoff = bytes(0,0)
    mmio.wr(R.DSPATILEOFF, 0); // Linear: tileoff = 0 (was StartY<<16|StartX)
    mmio.wr(R.PLANE_SIZE_1_A, encodeSize(fb.width, fb.height));
    mmio.wr(R.PLANE_POS_1_A, 0);
    // DSPSURF = GGTT byte offset of the surface (Linux skl_surf_address,
    // non-DPT path returns offset directly). Our buffer is at GTT offset
    // 0 (PTE[0]->phys), so offset 0 is correct — NOT a phys address.
    mmio.wr(R.DSPASURF, @as(u32, @intCast(fb.offset)) & ~@as(u32, 0xfff));
    mmio.wr(R.DSPACNTR, PLANE_CTL_ENABLE | DSPCNTR_FORMAT);
    // readback-verify: which plane writes actually commit
    mmio.say("  rb[A] DSPACNTR="); mmio.sayHex(mmio.rd(R.DSPACNTR));
    mmio.say(" DSPASTRIDE="); mmio.sayHex(mmio.rd(R.DSPASTRIDE));
    mmio.say(" DSPASURF="); mmio.sayHex(mmio.rd(R.DSPASURF));
    mmio.say(" DSPALINOFF="); mmio.sayHex(mmio.rd(R.DSPALINOFF));
    mmio.say(" DSPATILEOFF="); mmio.sayHex(mmio.rd(R.DSPATILEOFF)); mmio.say("\n");
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
    mmio.say("i915: pipe=A(PIPEA*/DSP A-bank) plane=1(hires) transcoder=EDP\n");
    transcoder.setup(mode.*, link.*);
    cursorOff(); // Update_Cursor(Default_Cursor)
    setupDisplay(fb, mode, fb.bpc != mode.bpc);
    setupHiresPlane(fb);
    panelFitterOff();
    cursorOff(); // Update_Cursor(Pipe_Cfg.Cursor) — default off
    transcoder.on(mode.*, link.*);
}

// ---- M2 atomic pageflip ------------------------------------------------------
// On SKL the hires plane's surface register (DSPASURF) doubles as the
// pageflip request: writing a new GGTT byte offset while the pipe is live
// arms an async flip the display engine applies at the next vblank — the
// hardware does the commit, no modeset re-run, no blank. This is the real
// atomic-commit mechanism M2 exercises: check/test stage the candidate,
// commit writes the surface, vblank delivers the event.
//
// The surface value is the GGTT byte offset (same encoding setupHiresPlane
// uses: fb.offset already == gtt_page*4096, low 12 bits ignored by HW).

// Program the plane's surface to a new GGTT offset — the flip request.
// Does NOT touch stride/size/pos/format: a same-mode flip only swaps the
// scanned buffer. Readback-verified by the caller.
pub fn pageflipSurface(gttByteOffset: u64) void {
    mmio.wr(R.DSPASURF, @as(u32, @intCast(gttByteOffset)) & ~@as(u32, 0xfff));
}

// Read back the currently-programmed surface offset (for flip verify).
pub fn surfaceOffset() u32 {
    return mmio.rd(R.DSPASURF);
}

// Display-engine interrupt IIR — the polled vblank/flip event source.
// DEIIR (0x044008) latches which DE interrupt fired; DEIMR (0x044004)
// unmasks the sources we want. We enable pipe-A vblank + plane-flip and
// poll IIR for edges — real hardware events, delivered by polling since
// consoleMode has no IRQ/APIC path armed.
pub const DE_IMR = R.DEIMR;
pub const DE_IIR = R.DEIIR;

// Unmask display-engine vblank + plane-flip-done interrupts.
pub fn vblankEnable() void {
    // The DE*/SDE* interrupt quartets are ISR(status)/IMR(mask, active-
    // low)/IIR(identity, write-1-clear)/IER(enable, active-high).
    // vblankEnable historically wrote ONLY DEIMR=0 — on T590 (Ironlake,
    // NOT the SKL the comments assumed) DEIER reads back 0, so no
    // source was ever enabled and DEIIR stayed 0 forever (kstat
    // vb_raw=0). Enable BOTH engines' IERs and unmask both IMRs; we
    // only READ the IIRs so extra sources are harmless noise bits.
    mmio.wr(R.DEIMR, 0);
    mmio.wr(R.DEIER, 0xFFFF_FFFF);
    mmio.wr(R.SDEIMR, 0);
    mmio.wr(R.SDEIER, 0xFFFF_FFFF);
    // Ironlake legacy bank (T590 = Arrandale = gen5, NOT SNB): the
    // DE*/SDE* quartets above are SNB+ engine regs and never carried
    // per-pipe vblank here — kstat read them all 0 while FRMCNT
    // ticked 60Hz. ILK routes pipe interrupts through IIR/ISR/IMR at
    // 0x20840/0x20830/0x20820. IMR bit=1 masks, so write 0xFFFF0000:
    // unmask the low 16 bits (per-pipe interrupt space) while keeping
    // hotplug/FM/MST-class upper sources masked — we have no IRQ
    // handler and an unmasked storm would livelock the shell.
    mmio.wr(R.LGC_IMR, 0xFFFF_0000);
}

// Read + clear the display-engine interrupt status. Returns raw IIR.
pub fn vblankPoll() u32 {
    const s = mmio.rd(R.DEIIR);
    if (s != 0) mmio.wr(R.DEIIR, s); // write-1-to-clear the serviced bits
    const s2 = mmio.rd(R.SDEIIR);
    if (s2 != 0) mmio.wr(R.SDEIIR, s2);
    // Ironlake legacy IIR (0x20840): gen<=5 identity register — latches
    // which unmasked source fired. T590 kstat showed DEIIR/SDEIIR/IMR
    // space all dead; this is the remaining candidate. Ack by writing
    // the latched ISR bits back to ISR (gen<=5 clear semantics); if
    // the write doesn't take, IIR stays nonzero — harmless now that
    // present.zig edge-aligns commits on FRMCNT (rate self-limits).
    const s3 = mmio.rd(R.LGC_IIR);
    if (s3 != 0) mmio.wr(R.LGC_ISR, mmio.rd(R.LGC_ISR));
    return s | s2 | s3;
}
