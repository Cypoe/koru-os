# M0 — i915/libgfxinit static scanout on ThinkPad T590 (KBL iGPU-630)

Commission: `session/m0-i915-BRIEF.md`. Port libgfxinit's Skylake/KBL
display-init path to Zig in `koru/native/`, light the eDP panel with a dumb
scanout buffer, produce a bootable ISO. Real hardware only — user flashes,
screen is the oracle. Receipts: `hc send t1 '📨 ...'` + prose baton + this file.

## Toolchain (measured this session, macOS)

- koruc: `~/src/koru-cypoe/zig-out/bin/koruc` (0.1.7, macOS build)
- stdlib: `KORU_STDLIB=~/src/koru-cypoe/koru_std`
- zig: `/opt/homebrew/bin/zig` (0.15.2)
- Build: `KORUC=... KORU_STDLIB=... ZIG=/opt/homebrew/bin/zig bash scripts/build-native.sh <prog.k> <out.elf>`
  (build-native.sh's W:-path defaults are for the Windows box; env overrides work — from prose baton 2026-11-07)
- ISO recipe (from baton): isotree with grub.cfg (gfxterm 1920x1080x32, serial) ->
  `docker koruos-amd64 grub-mkrescue` -> PATCH MBR byte 0x1be = bootable 0x83, LBA 0x10.
  docker exists at /usr/local/bin/docker.
- Program .k for native builds: `koru/fb/tests/boot_fb.k` was the proven one.

## Boot-state facts (from commit 7c5b572 + baton)

- boot.zig kmain: pmm.init -> [fullBoot: acpi,pci,ioapic,user,kbd,mouse,smp] ->
  fb.init(mbi) -> consoleMode? shell.run() (noreturn text console, PROVEN on T590)
  -> else fbDiag fast path (fullBoot=false: red fill + green triangle, halt).
- fullBoot path triple-faulted in QEMU after ioapic init (baton) — unverified on HW.
- consoleMode=true + fullBoot=false = the proven ThinkPad path: text console on
  the GRUB/VBE-adopted linear fb (mb2 tag8, 1920x1080x32, phys addr known).
- fb.zig adopts mb2 tag8 phys/pitch/w/h; fb_base is identity-mapped.

## Design decision (M0)

Scanout buffer = the SAME physical pages as the adopted VBE fb. GTT PTEs map
those phys pages; the i915 plane points at them. Console text.zig keeps drawing
to fb_base (phys P) -> panel shows the console THROUGH the real GPU modeset.
Zero compositing needed. Fallback if that phys isn't GTT-mappable: pmm pages.

## libgfxinit port map (source: ~/src/koru-desktop/session/m6-i915/libgfxinit)

Config (fixed): Gen=Skylake, PCH=Sunrise_Point, CPU=Kabylake (detect by PCI
8086:59xx), Panel_1=eDP, Panel_2=Disabled, Analog_I2C=PCH_DAC,
Default_MMIO=0xe0000000 (BAR0 should match), DYN_CPU=y.

Derived config values for our fixed config (from config.ads.template):
- MMIO_GTT_64_Offset=0x800000, GTT_PTE_Size=8 (Has_64bit_GTT: Broadwell_On)
- GTT base = MMIO_BAR0 + 0x800000; PTE index = byte_off/4096
- Fence_Base=0x100000, Fence_Count=32 (Ivybridge_On)
- GMA_Phys_Base_Index=0x5c (PCI cfg, stolen mem base), 32-bit
- Default_CDClk=337.5MHz, Default_RawClk=24MHz (SKL, fractional rawclk:
  Cannon_Point_On -> Has_Fractional_RawClk; 24MHz vs 19.2 by SFUSE_STRAP bit8)
- Max_Pipe=Tertiary exists (Ivybridge_On) but we use Primary only
- Has_DDI_D/E true (not LP), Last_Digital_Port=DIGI_E; eDP -> DIGI_A always
- Is_FDI_Port(eDP)=False -> NO FDI path needed
- Has_PCH_Aux_Channels, Has_PCH=true; PCH_RAWCLK_FREQ written at init
- Use_PDW_For_EDP_Scaling/Has_Pipeconf_Misc: Haswell_On-only -> false for SKL?
  CAREFUL: Has_Pipeconf_Misc is <hswbool> = Broadwell_On -> SKL=false.
  Has_Pipeconf_BPC = not CPU_Haswell -> true for SKL.
  Use_KBL_DDI_Buf_Trans = CPU_Kabylake -> TRUE — KBL buffer translation tables!
  Has_Iboost_Config = Skylake_On -> true. DDI_Buffer_Iboost = 3 if Is_ULX or
  (KBL and Is_ULT) else 1.

Enable_Output(eDP) call chain (hw-gfx-gma.adb):
Fill_Port_Config -> Power_And_Clocks.Power_Up(eDP)=PD_On(DDI_AE) ->
Connector_Info.Preferred_Link_Setting -> Connectors.Prepare ->
PLLs.Alloc -> Port_Detect.Clear_Hotplug_Detect -> Connectors.Pre_On ->
Display_Controller.On (Pipe_Setup) -> Connectors.Post_On.
On fail: retry DP lane configs (Next_Link_Setting) x2 tries.

GTT/FB: Write_GTT(GTT_Page, phys_addr, valid) -> 64-bit PTE at
MMIO+0x800000+page*8, value=(addr & 0x7ffffffff000)|1. FB.Offset is a byte
offset; GTT page = Offset/4096. For our own mapping we bypass
Setup_Default_GTT and write PTEs directly.

## Files to port (skylake set = skylake/ + haswell_shared/ + common/ + dyncpu)

Done reading: hw-gfx.ads, hw-gfx-gma.ads, hw-gfx-gma.adb (all),
config_helpers.adb, skylake/power_and_clocks.adb, registers.adb,
config.ads.template, registers.ads (enum->offset map, script-generate).

TODO read+port (bodies): pcode, panel, plls(+dpll,dpll_0,spll), port_detect,
connector_info, dp_info, dp_aux_ch, dp_aux_request, dp_training, dp_dual_mode?,
connectors(haswell_shared), connectors-ddi, ddi_phy.ads, ddi-buffers,
pipe_setup, transcoder, pch-transcoder, pch.ads, pch-vga?(Legacy_VGA_Off),
i2c/edid (maybe skippable for fixed mode), display_probing, sideband? (check
if eDP path touches), framebuffer_filler (trivial).

## Zig layout plan

koru/native/i915.zig root + i915/*.zig per Ada package. regs.zig generated
from registers.ads by script (NAME => 16#off# / Register_Width=4).
MMIO: volatile u32 loads/stores at identity-mapped BAR0 (mmio.map already
identity-maps). Timeouts via PIT/tsc — check what kernel has (runtime clock?).

## PORT PROGRESS (files on disk under koru/native/i915/)

- regs.zig — GENERATED, 1105 symbols (script /tmp/gen_regs.py; regenerate if
  registers.ads changes). Byte offsets, use as mmio.rd(R.X)/wr(R.X,v).
- mmio.zig — DONE. setBase(bar0,gtt), rd/wr/postingRead, wait/waitSet/waitUnset
  (ms via ukplat_monotonic_clock), isSet/setMask/unsetMask/unsetAndSet,
  writeGtt/readGtt (64-bit PTE @ gtt64 = bar+0x800000, mask 0x7ffffffff000|1),
  dumpReg DIAG, say/sayDec. Fences NOT ported (Linear fb only).
- pcode.zig — DONE. mailboxWriteRead/Write/Request; GT_MAILBOX regs via R.*.
- port_detect.zig — DONE (eDP-only). edpValid(), hotplugDetect(),
  clearHotplug(). Reads DDI_BUF_CTL_A strap bit0, HOTPLUG_CTL + SHOTPLUG_CTL.
- power.zig — DONE (skylake). initialize() [NDE_RSTWRN_OPT, PG0 wait, PW1,
  MISC_IO, LCPLL1 enable+lock, chicken DCPR bit13, ARB_CTL FBC wake, CDCLK
  337.5], pdOn/pdOff, powerUpEdp()=pdOn(DDI_AE), getRawClock() 24/19.2MHz
  via SFUSE_STRAP bit8, cdclk/maxCdclk state. DFSM decode: {0:675,1:540,
  2:450,3:337.5} — VERIFIED against Ada constants (0*2^23 names 675MHZ).

- connector_info.zig — DONE (eDP path). preferredLinkSetting(mode,link):
  panel.on -> dp.readCaps -> readEdpRates -> preferredLinkSetting ->
  sink wake DPCD 0x600 (rev>=0x11) -> MST check 0x21/0x111 (rev>=0x12).
  nextLinkSetting -> dp.nextLinkSetting. defaultBpc()=6 for eDP/DIGI_A.
- dp.zig — DONE (dp_info port). Types Bandwidth/LaneCount/DPCaps/DPLink/
  Mode (M1920x1080_60 const), symbolRate, readCaps (DPCD 0x0 len15),
  readEdpRates (0x700 caps + 0x10 rates, eDP rev>=3), minimumLaneCount
  (dotclk / ((symrate*8/3)/bpc)), preferred/nextLinkSetting,
  calculateMN (FIXED_DATA_N=0x800000, FIXED_LINK_N=0x80000, M_N_Max=2^24-1),
  LinkStatus decode (DPCD 0x202 6B), allCRDone/allEQDone/maxRequestedVS/Emph.
  NOTE: readEdpRates maxRate*20 is in kHz*20 units per Ada (Rate is in
  20kHz? — Ada multiplies Word16 by 20 then compares >=540_000; ported
  verbatim, units self-consistent).
  auxRead/auxWrite declared -> aux.zig (DONE).
- aux.zig — DONE (native AUX only; I2C-over-AUX/DDC NOT ported).
  Config: Has_PCH_Aux_Channels=false for SKL -> DDI_AUX_CTL_A +
  DDI_AUX_DATA_A_1..5; Need_DP_Aux_Mutex=false; 2xclk=0.
  auxRequestLow: pack req into 5 dwords BE, CTL=SEND_BUSY|DONE|
  clr-errors|TIMEOUT_600US|MSGLEN<<20, wait !SEND_BUSY(10ms),
  respLen=MSGLEN field (clamp 20). doAuxRequestLow=3 tries;
  doAuxRequest=32 tries on AUX-defer +500us, final Is_Aux_Ack.
  auxRead(addr,buf<=16): native read hdr4; auxWrite(addr,data<=16): hdr4+data.
  mmio.zig gained sleepMs/sleepUs (busy-wait on monotonic clock).
- types.zig — DONE. GPU_Port/PCH_Port/Pipe/Display/BPC/Mode_Type/
  Framebuffer(offset=byte->GTT page,tiling)/Port_Config/Invalid_Mode.
  NOTE: eDP uses Display=DP in libgfxinit (eDP-ness = Panel+port).
- pll.zig — DONE. PLL enum {Invalid,DPLL0,DPLL1,DPLL3,DPLL2} (twisted),
  alloc(): DIGI_A->checkLinkRateDpll0(DPLL_CTRL1 bits1-3 rate+bit0
  OVERRIDE) else allocConfigurable (share or DPLL.On, useCount<=2).
  dpllOn: Display=DP -> DPLL_CTRL1 linkRateBits|OVERRIDE per-PLL shift
  {DPLL1:6,DPLL2:12,DPLL3:18}; non-DP -> calculateDpll (ported,
  CF 9.6/9.0/8.4GHz, even+odd divs, P/Q/K) + CFGR1/2. Enable via
  DPLL_CTL {DPLL1:LCPLL2_CTL,DPLL2:WRPLL_CTL_1,DPLL3:WRPLL_CTL_2},
  wait DPLL_STATUS lock {DPLL1:bit8,DPLL2:bit16,DPLL3:bit24}.
  regVal: DPLL0=0,DPLL1=1,DPLL3=3,DPLL2=2 -> PLL hint for DPLL_CTRL2.
- panel.zig — DONE (Panel_1 only). PP regs=PCH_PP_*; Has_PP_Divisor_Reg
  =FALSE -> cycle delay in CONTROL[8:4] (100ms units, +1); Port_Select=0;
  Write_Prot=false -> just POWER_DOWN_ON_RESET. delaysUs defaults
  {210000,50000,500000,50000,510000}us; setupPPSequencer(defaultDelays)
  reads/writes ON/OFF_DELAYS (up->bl forced 100us). on(): TARGET_ON +
  wait STATUS ENABLED|SEQ_NONE 1000ms; backlightOn(): BXT_BLC_PWM_CTL_1
  ENABLE(bit31) + PP_CONTROL BL_ENABLE(bit2). off() for completeness.
- port_detect.zig — REWRITTEN for SKL: Has_HOTPLUG_CTL=Gen_Haswell=
  FALSE -> HPD ONLY in SHOTPLUG_CTL (input 1<<28, status 3<<24, long
  1<<25, detect mask 0x03030303, invert unused). eDP valid =
  DDI_BUF_CTL_A bit0 strap.
- connectors-ddi.adb READ (768 lines). Resolved SKL config:
  Has_DDI_PHYs=Gen_Broxton=FALSE -> NO ddi_phy; buffer translations
  via BUF_TRANS regs (KBL tables, Use_KBL_DDI_Buf_Trans=true);
  Has_Per_DDI_Clock_Sel=FALSE -> DPLL_CTRL2 DDIx_SELECT(shift{1,4,7,10,13}
  mask 3<<s) + OVERRIDE(1<<(s-1)) + CLOCK_OFF(1<<(14+s));
  End_EDP_Training_Late=FALSE -> TP_None immediate, DIGI_A skips
  MIN_IDLES wait. DDI regs per port: BUF_CTL, BUF_TRANS[20],
  DP_TP_CTL, DP_TP_STATUS(B only), PORT_CLK_SEL(unused on SKL).
  TP_CTL: TRANSPORT_ENABLE|ENHANCED?|LINK_TRAIN{PAT1=0,PAT2=1<<8,
  IDLE=2<<8,PAT3=4<<8,NORMAL=3<<8}|SCRAMBLE_DISABLE for PAT1-3.
  Set_Signal_Levels: BUF_CTL BUF_ENABLE|TRANS_SELECT(sel<<24)|
  PORT_WIDTH(lanes<<1); sel = VS/Emph table {VS0:E0-3->0-3,VS1:E0-2->4-6,
  VS2:E0-1->7-8,VS3:E0->9}; delay 600us if newly enabled.
  Max_V_Swing=VS2 (EDP_Low_VS=false), Max_Pre_Emph table
  {VS0:E3,VS1:E2,VS2:E1,VS3:E0}. Digital_Off: clear BUF_ENABLE+TP_CTL
  TRANSPORT_ENABLE, wait IDLE_STATUS(bit7), DPLL_CTRL2 CLOCK_OFF.
  Initialize: writes 20 BUF_TRANS per port DIGI_A..E (Kaby_Lake_Trans_DP
  vals[0..17] + Skylake_Trans_HDMI(0)=(0x18,0xac) at 18,19 since
  Default_DDI_HDMI_Buffer_Translation=0 for KBL) + DISPIO_CR_TX_BMU_CR0
  iboost=1 at shifts {8,11,14,17,20} value1.
  Pre_On(DIGI_A): DPLL_CTRL2 select=PLL hint, then Train_DP.
  Post_On(DIGI_A): nothing for eDP (End_EDP_Training_Late=false,
  Display!=HDMI/VGA). Connectors.Post_On: Panel.Backlight_On (+AUX BL
  if EDP_AUX_Backlight=false -> skip).
- connectors.adb(haswell_shared) READ: Prepare=Success:=True;
  Pre_On->DDI.Pre_On; Post_On->DDI.Post_On+Panel.Backlight_On;
  Initialize->DDI.Initialize.
- dp_training.adb READ (414): Train_DP flow = TP1+levels(VS0,E0) ->
  Sink_Init(AUX 0x100 rate|lanes[|0x80 enh],0x107 0,1) -> Sink pattern
  TP1 -> CR loop 32 tries (delay 100us or auxRdInt*4000us if 5.4GHz;
  retry rules) -> EQ pattern (TP3 if tps3 both else TP2) -> EQ loop 6
  tries (400us or interval*4000) -> Sink TP_None + Set_Pattern(TP_None)
  -> Success=EQ_Done else Off. trainingSet byte: VS|E<<3|bit2 if
  VS==MaxVS|bit5 if E==MaxEmph(VS).
  Sink AUX addrs: 0x100 BW/lane, 0x102 TP set, 0x103 lane levels,
  0x107 downspread/coding, status read DPCD 0x202 via dp.readLinkStatus.
- pipe_setup.adb+ads READ (1219+414). Controller_Type=per-pipe reg map;
  Primary uses PLANE_CTL=DSPACNTR, KEYVAL/MSK, OFFSET=DSPATILEOFF,
  POS/SIZE/STRIDE/SURF, PS_CTRL_1/2_A, WIN_POS/SZ_1/2_A, WM_LINETIME_A,
  PLANE_BUF_CFG/COLOR_CTL/WM[8]_1_A, PLANE_2_*, CUR_BUF_CFG/CUR_WM[8],
  MBUS_DBOX_CTL=PIPE_MBUS_DBOX_CTL_A, PIPE_CHICKEN=PIPEA_CHICKEN,
  PLANE_AUX_DIST_1_A, PIPESRC=PIPEASRC, PIPEMISC=PIPEAMISC.
  Has_Plane_Control=? (SKL likely true->plane path w/ watermarks).
  Setup_Hires_Plane: PLANE_COLOR_CTL gamma-disable, AUX_DIST=0,
  PLANE_CTL=ENABLE|TILED|ROT|RGB_32B_8888|ARB_SLOTS(1 if
  Need_Pipe_Arb_Slots)|gamma_dis, OFFSET=StartY<<16|StartX,
  SIZE=(W-1)|(H-1)<<16, STRIDE=pitch, POS=0, SURF=FB.Offset&~0xfff.
  DSPCNTR path (no Plane_Control): PRI=6<<26 fmt + tiled + trickle;
  DSPSTRIDE bytes; DSPLINOFF/DSPTILEOFF/DSPSURF per Has_DSP_Linoff/
  Has_DSPSURF; DSPCNTR=ENABLE|PRI|tiled.
  Setup_Display: PIPESRC=(H-1)|(W-1)<<16; PIPEMISC=BPC_Conf|misc if
  Has_Pipeconf_Misc(=false for SKL->skip? verify); watermarks if
  Has_Plane_Control; MBUS_DBOX credits if Has_Mbus_Dbox_Credits.
  Setup_Scaling: if Requires_Scaling -> Has_Plane_Control?
  Skylake_Pipe_Scaler(PS_CTRL_1=ENABLE|Limits.Control,
  WIN_POS_1, WIN_SZ_1) else PF/GMCH. Our 1920x1080->1920x1080 = no
  scaling -> Panel_Fitter_Off.
  Pipe_Setup.On: Transcoder.Setup -> Setup_FB(Setup_Display+
  Setup_Scaling) -> Update_Cursor(Default off) -> Transcoder.On.
  Legacy_VGA_Off: SR01 screen-off + VGACNTRL VGA_DISPLAY_DISABLE;
  needs Port_IO outb/inb 0x3c4/0x3c5 — add to mmio or small portio.

## RESOLVED CONFIG (Gen=Skylake, PCH=Sunrise_Point, T590 = KBL-R ULT)

Device detect (config template masks): KBL-U (id&0xffcd)==0x5901 or
(id&0ffce)==0x5906; KBL-Y (id&0xffcf)==0x5905/0x590e; KBL (id&0xffc7)==
0x5902 or (id&0xffcf)==0x5908/0x590b/0x590d; CFL-U (id&0xfff0)==0x3ea0;
CFL (id&0xfff0)==0x3e90 (includes Whiskey Lake = T590's likely 0x3E9x);
SKL variants 0x19xx. T590 iGPU-630/UHD620 = KBL-R ULT -> Is_ULT=true,
Is_LP=true -> Has_DDI_D/E=FALSE -> Last_Digital_Port=DIGI_C (eDP still
DIGI_A); DDI_Buffer_Iboost=3; BUF_TRANS table = Kaby_Lake_U_Trans_DP
(Is_ULT, Use_KBL_DDI_Buf_Trans=true); Has_PCH_DAC=false.

Transcoder: Has_EDP_Transcoder=true -> eDP/DIGI_A uses Trans_EDP regs
(PIPE_EDP_*), NOT Trans_A. Trans_EDP map: HTOTAL_EDP,HBLANK_EDP,
HSYNC_EDP,VTOTAL_EDP,VBLANK_EDP,VSYNC_EDP,PIPE_EDP_CONF,
PIPE_EDP_DATA_M1/N1,PIPE_EDP_LINK_M1/N1,PIPE_EDP_DDI_FUNC_CTL,
PIPE_EDP_MSA_MISC; CLK_SEL+PIPE_ARB_CTL=Invalid.

Pipe (Primary, Has_Plane_Control=true): regs per pipe_setup.ads —
PLANE_CTL=DSPACNTR, KEYVAL/MSK=PLANE_KEYVAL/MSK_1_A, OFFSET=DSPATILEOFF,
POS/SIZE/STRIDE/SURF, PS_CTRL_1/2_A, PS_WIN_POS/SZ_1/2_A, WM_LINETIME_A,
PLANE_BUF_CFG/COLOR_CTL/WM[8]_1_A, PLANE_2_*, CUR_BUF_CFG_A/CUR_WM_A[8],
MBUS_DBOX_CTL=PIPE_MBUS_DBOX_CTL_A, PIPE_CHICKEN=PIPEA_CHICKEN,
PLANE_AUX_DIST_1_A, PIPESRC=PIPEASRC, PIPEMISC=PIPEAMISC.
Cursors(Primary): Has_Ivybridge_Cursors=true -> CUR_CTL_A/CUR_BASE_A/
CUR_POS_A/CUR_FBC_CTL_A. Needs_Even_Source_Width=false,
Disable_Trickle_Feed=TRUE(not HSW/I945), Has_Wide_Watermarks=false
(PLANE_WM_BLOCKS_MASK=0x3ff), Has_Plane_Color_Control=false (skip
PLANE_COLOR_CTL write; PLANE_CTL gets PLANE_GAMMA_DISABLE bit13),
Need_Pipe_Arb_Slots=false, Has_Mbus_Dbox_Credits=false,
Has_Skylake_Scaler_Limits=true, Has_DSP_Linoff=false, Has_DSPSURF=true
(but Plane_Control path used, DSP regs unused), VGA_Plane_Workaround=
false, Pipe_Enabled_Workaround=false(CPU_Broadwell), Has_Pipeconf_Misc=
TRUE -> PIPEMISC=BPC_Conf(BPC,Dither)|PIXEL_ROUNDING_TRUNC(1<<8)|
HDR_MODE_PRECISION(1<<23); Has_Pipeconf_BPC=true -> BPC_Conf has
TRANS_CONF_BPC {6:2<<5,8:0,10:1<<5,12:3<<5}|DITHER(1<<4 if dither).
CONF=PIPE_EDP_CONF gets TRANS_CONF_ENABLE(1<<31) ONLY (BPC goes to
PIPEMISC since Has_Pipeconf_Misc). MSA_MISC=SYNC_CLK(1)|BPC_MSA
{6:0,8:1<<5,10:2<<5,12:3<<5,16:4<<5}.

Setup_Hires_Plane (non-rotated): AUX_DIST=0; PLANE_CTL=ENABLE(1<<31)|
TILED_SURFACE(Linear=0)|ROTATION(0)|RGB_32B_8888(4<<24)|ARB_SLOTS(0)|
PLANE_GAMMA_DISABLE(1<<13); OFFSET=StartY<<16|StartX; SIZE=(W-1)|(H-1)<<16;
STRIDE=FB_Pitch(stride)=Div_Round_Up(bytes,64) for Linear;
POS=0; SURF=FB.Offset&~0xfff.
Setup_Display: PIPESRC=(H-1)|(W-1)<<16; watermarks: PLANE_BUF_CFG_1_A=
Encode_Buffers(0,150)=(149<<16)|0, PLANE_WM_1_A_0=ENABLE|LINES(2)|
BLOCKS(150); PLANE_2: (150,11)->(160<<16)|150? Encode_Buffers(150,11)=
(150+11-1)<<16|150=(160<<16)|150, WM BLOCKS(11); CUR: (161,8)->
(168<<16)|161, BLOCKS(8); WM_LINETIME_A untouched? (Clear_Watermarks
writes 0; Setup_Watermarks does NOT write WM_LINETIME — only BUF_CFG+WM0).
Setup_Scaling: 1920x1080->1920x1080 => Requires_Scaling=false ->
Panel_Fitter_Off: PS_CTRL_1_A unset ENABLE_SCALER(1<<31), PS_WIN_SZ_1_A=0,
PS_CTRL_2_A+PS_WIN_SZ_2_A same if regs exist.
Pipe_Setup.On order: Transcoder.Setup(timings+MN+MSA_MISC, CLK_SEL
skipped for EDP) -> Update_Cursor(Default)->Setup_Display->
Setup_Scaling -> Update_Cursor(cfg)->Transcoder.On(DDI_FUNC_CTL write +
ENABLE + CONF=ENABLE).
Transcoder.Configure DDI_FUNC_CTL (Trans_EDP): DDI_SELECT(DIGI_A=0)|
MODE_SELECT_DP_SST(2<<24)|BPC{6:2<<20,8:0,...}|VSYNC/Hsync(Mode flags
both false->0)|EDP_SELECT(ALWAYS_ON=0 since Primary+!Use_PDW)|
PORT_WIDTH{l1:0,l2:1<<1,l4:3<<1}. Then On: set DDI_FUNC_CTL_ENABLE
(1<<31), CONF=ENABLE, posting read.
Transcoder.Setup_Link: calculateMN -> DATA_M1=(63<<25)|Data_M,
DATA_N1=Data_N, LINK_M1=Link_M, LINK_N1=Link_N (64-bit? regs are 32-bit
writes of M/N values which fit 24 bits). Encode(LSW,MSW)=(MSW-1)<<16|
(LSW-1) for HTOTAL etc.

DP_Training (dp_training.adb full read): TPS3_Supported=true for DDI.
Train_Set{VS,Emph} start VS0/E0. Set_Pattern=ddi.setTrainingPattern,
Set_Signal_Levels=ddi.setSignalLevels, Off=ddi.digitalOff.
Sink_Init: AUX write 0x100 [bwEnum,laneCount|(0x80 if enh)], then
0x107 [0,1]. Sink_Set_Training_Pattern: AUX write 0x102
[TPcode{TP1=0x21,TP2=0x22,TP3=0x23,idle/none=0}, T_Set x lanes if
pattern<TP_Idle]. Sink_Set_Signal_Levels: AUX write 0x103 [T_Set x
lanes]. Sink_Adjust_Training: readLinkStatus(0x202,6B); CR_Done=allCR;
EQ_Done=allEQ; Success stays true only if (CR_Done or !CR_Was_Done);
if !EQ_Done update VS=MaxRequestedVS clamp Max_V_Swing(VS2 for us),
Emph=MaxRequestedEmph clamp Max_Pre_Emph(VS){VS0:E3,VS1:E2,VS2:E1,else:E0}.
Train_DP: TP1+levels -> Sink_Init -> sink TP1 -> CR loop 32 tries
(delay CR_Delay=100us or auxRdInterval*4000us if b5_4; retry logic:
same VS->Retries++ exit at 4, VS changed->Retries=0 exit if last==MaxVS;
each iter Set_Signal_Levels+Sink_Set_Signal_Levels) -> Success=CR_Done
-> EQ pattern (TP3 if both tps3 else TP2) -> EQ loop 6 tries (EQ_Delay
=400us or interval*4000) -> Sink TP_None(0x102 write [0]) +
Set_Pattern(TP_None)->NORMAL -> Success=EQ_Done else Off(port).
Training_Set byte: VS|E<<3|0x04 if VS==MaxVS|0x20 if Emph==MaxEmph(VS).

connectors-ddi constants (all confirmed):
BUF_CTL: ENABLE=1<<31, TRANS_SELECT_MASK=15<<24 (sel<<24),
PORT_REVERSAL=1<<16, IDLE_STATUS=1<<7, PORT_WIDTH_MASK=7<<1
{1lane:0,2:2,4:6}, DETECTED bit0, TRANS_SELECT sel 0..9 per VS/Emph
{VS0:E0-3->0-3,VS1:E0-2->4-6,VS2:E0-1->7-8,VS3:E0->9}.
TP_CTL: TRANSPORT_ENABLE=1<<31, ENHANCED=1<<18, LINK_TRAIN_MASK=7<<8
{PAT1=0,PAT2=1<<8,PAT3=4<<8,IDLE=2<<8,NORMAL=3<<8}, SCRAMBLE_DISABLE=
1<<7 (PAT1-3 only). Set_TP_CTL writes full reg TRANSPORT_ENABLE|
ENHANCED?|LINK_TRAIN(pat). Set_Training_Pattern: pat<TP_Idle->direct;
else TP_Idle first, then if Port==DIGI_A skip MIN_IDLES wait ->
TP_None (End_EDP_Training_Late=false).
Digital_Off: clear BUF_ENABLE if set, clear TP_CTL TRANSPORT_ENABLE,
wait BUF_CTL IDLE_STATUS if was enabled, DPLL_CTRL2 CLOCK_OFF(DIGI_A=
1<<15) since Has_Per_DDI_Clock_Sel=false & !Has_DDI_PHYs.
Pre_On: Display!=VGA -> DPLL_CTRL2 unsetAndSet(DIGI_A: CLOCK_OFF|SELECT_
MASK=1<<15|3<<1, set PLL_Hint<<1 | OVERRIDE 1<<0); Display==DP ->
Train_DP. Post_On: Port==DIGI_A + End_EDP_Training_Late=false ->
nothing; Display=DP -> nothing (others case). Off->Digital_Off.
Post_Reset_Off: DPLL_CTRL2 set CLOCK_OFF for ALL digital ports
{A:1<<15,B:1<<16,C:1<<17,D:1<<18,E:1<<19}.
Initialize: BUF_TRANS[20] per port DIGI_A..Last_Digital_Port
(DIGI_C if Is_LP!) + DIGI_E if Is_FDI_Port(Analog)=false -> skip;
table=Translations(port): EDP_Low_VS=false -> Use_KBL_DDI_Buf_Trans?
Is_ULT->Kaby_Lake_U_Trans_DP, Is_ULX->Kaby_Lake_Y_Trans_DP, else
Kaby_Lake_Trans_DP; entries[0..17]=table, [18..19]=Skylake_Trans_HDMI
(Default_DDI_HDMI_Buffer_Translation=0 for KBL)->(0x18,0xac).
DISPIO_CR_TX_BMU_CR0: unsetAndSet mask {DISBL 0x1f<<23, SCTL4 7<<20,
SCTL3 7<<17, SCTL2 7<<14, SCTL1 7<<11, SCTL0 7<<8} set iboost<<each
shift {20,17,14,11,8}; iboost=3 if ULT else 1.
Set_Signal_Levels: wasEnabled=BUF_CTL&ENABLE; sel per table; unsetAndSet
BUF_CTL {TRANS_SELECT_MASK|PORT_REVERSAL|PORT_WIDTH_MASK} set
ENABLE|sel<<24|PORT_WIDTH(laneCount); posting read; if !wasEnabled
sleepUs(600).

GTT: Write_GTT 64-bit PTE=(addr&0x7f_ffff_f000)|valid at gtt64 base
(BAR0+0x800000). Setup_Default_GTT: pages FB_First..FB_Last get
phys=PhysBase+PhysOffset+i*4096; +128 dummy pages continue phys.
FB_First_Page=Phys_Offset(FB)/4096, FB_Pages=ceil(FB_Size/4096),
FB_Size=Pixel_To_Bytes(Stride*V_Stride)=Stride*V_Stride*BPC/2.
GTT_Range=0..0x7ffff (524287), GTT_Rotation_Offset=0x40000.
Validate_FB: Valid_Stride + First_Page in range + Last+128 in range
(+rot90 checks skipped, no rotation). Stolen/aperture checks SKIPPED
for borrowed VBE buffer (not stolen mem necessarily) — our own
validate: phys+size sane.

PCH_RAWCLK_FREQ (Has_PCH=true, Has_Fractional_RawClk=true):
MASK=0x3fff<<16. FREQ(f): f32=(f/1e6)<<16 | (if Fraction_K=(f/1000)%1000
/=0 then (Div_Round_Closest(1000,Fraction_K)-1)<<26); No ICP_RAWCLK_NUM
(Need_Rawclk_Numerator=false). Div_Round_Closest(a,b)=(a+b/2)/b? verify
— likely (Num+Denom/2)/Denom. Raw_Clock from power.zig getRawClock() Hz
(24e6 or 19.2e6). Write PCH_RAWCLK_FREQ reg unsetAndSet(MASK,FREQ).

Enable_Output order (gma.adb): Fill_Port_Config(eDP->GPU DIGI_A,
Display=DP,Panel=Panel_1,Is_eDP=true,DP=Default_DP,Mode.BPC=Auto->
defaultBpc()=6 for eDP/DIGI_A!) -> Power_Up(Port)=power.powerUpEdp ->
Connector_Info.Preferred_Link_Setting=connector_info -> Connectors.
Prepare(=true) -> PLLs.Alloc -> per try(1..2): Clear_Hotplug ->
Pre_On(ddi: DPLL_CTRL2 select + Train_DP) -> Display_Controller.On
(pipe: transcoder.Setup+FB+cursor+transcoder.On) -> Post_On(ddi.
postOn + panel.backlightOn) -> fail? Display_Controller.Off+
Post_Off. PLLs.Free + Next_Link_Setting loop on link failure.
Mode.BPC=6 (eDP default) -> FB.BPC=8 -> Dither=TRUE.

M1920x1080_60 dotclock=60*2185*1135=148,858,500 Hz.

GMA Initialize order: setBase(defaults) -> pll init -> PCI dev init +
Check_Platform_PCI (vendor 0x8086 + Compatible_GPU) -> map BAR0 (res0,
MMIO len 0x800000? Dev.Map Res0 full; GTT at +0x800000 within same
BAR) -> Set_Register_Base -> Panel.Static_Init -> Setup_PP_Sequencer
-> Legacy_VGA_Off + Connectors.Post_Reset_Off (Clean_State=false) ->
Power_And_Clocks.Initialize (power.zig) -> Port_Detect.Initialize ->
Connectors.Initialize (ddi.initialize) -> PCH_RAWCLK_FREQ write.

## NEXT ACTIONS

1. Write i915/training.zig (dp_training port; needs ddi callbacks ->
   pass fn ptrs or make training.zig take the DDI module directly:
   simplest = training.zig calls ddi.setTrainingPattern etc. —
   circular import OK in Zig via lazy analysis? Use explicit param
   struct of fn pointers to be safe, or just have ddi.zig own the
   Train_DP wrapper calling training.zig functions that take the 3
   callbacks as args).
2. Write i915/ddi.zig (constants above; DIGI_A only + BUF_TRANS
   tables for A..C [Is_LP->Last=DIGI_C] + E skip; DPLL_CTRL2 helpers;
   digitalOff; preOn/postOn; initialize).
3. Write i915/transcoder.zig (Trans_EDP only).
4. Write i915/pipe.zig (Primary only: watermarks, hires plane, scaling
   off, cursor disable, transcoder setup/on).
5. Write i915/i915.zig top: pci find 0x8086 + KBL/CFL mask -> BAR0 ->
   mmio.setBase -> power.initialize -> port_detect.initialize ->
   panel.staticInit+setupPPSequencer -> legacyVgaOff (port IO 0x3c4/
   0x3c5 + CPU_VGACNTRL) -> ddi.postResetOff -> powerAndClocks init
   order per gma.adb -> PCH_RAWCLK -> then modeset(mbi): build FB
   {W=1920,H=1080,Stride=pitch/4,V_Stride=1080,BPC=8,Linear,Offset=0},
   writeGtt pages 0..N-1 = vbe_phys+i*4096 + 128 dummies, fill
   pattern via existing linear mapping, Enable_Output sequence.
   Staged say() markers per step; on failure say stage + Panel.Off.
6. boot.zig: after fb.init(mbi) call i915 (needs mbi fb fields: check
   fb.zig Info struct line ~181 + how boot.zig passes mbi).
7. pci.zig Device struct fields (line ~91) for bus/slot/func +
   barPhys(d,0) + setCommand MEM|BM bits.
8. Build: KORUC=~/src/koru-cypoe/zig-out/bin/koruc
   KORU_STDLIB=~/src/koru-cypoe/koru_std ZIG=/opt/homebrew/bin/zig
   bash scripts/build-native.sh prog.k out.elf — MUST add i915/*.zig
   to module list in build-native.sh.
9. ISO via docker grub-mkrescue + MBR patch (baton has recipe).
10. hc send t1 receipts + prose baton + NOTES.

Still TODO (read .adb then port)

Then: boot.zig hook (call i915 init after fb.init), build ELF
(KORUC=~/src/koru-cypoe/zig-out/bin/koruc KORU_STDLIB=~/src/koru-cypoe/koru_std
ZIG=/opt/homebrew/bin/zig bash scripts/build-native.sh prog.k out.elf),
ISO via docker koruos-amd64 grub-mkrescue + MBR patch (baton recipe).


## BUILD STATE (2026-11-07, this session) — ELF+ISO GREEN, HW UNVERIFIED

All port modules written and COMPILED: aux, connector_info, ddi,
dp, i915 (top), mmio, panel, pcode, pipe, pll, port_detect, power,
regs, training, transcoder, types. boot.zig calls i915drv.init()
after fb.init(mbi); fb.zig gained scanout() (phys/pitch/w/h of the
adopted linear FB — identity map, phys==VA).

Working build recipe (build-native.sh's copy-to-temp BREAKS koruos
path resolution — {{ ENTRY }}/../.. needs the real file location):
  1. cd session/m0-i915/work && KORU_STDLIB=~/src/koru-cypoe/koru_std \
     ~/src/koru-cypoe/zig-out/bin/koruc \
     /Users/larsde/src/koru-os-thinkpad/koru/fb/tests/boot_fb.k
     -> emits koru/fb/tests/output_emitted.zig (backend exec failure
     on koruos_fb_* symbols is EXPECTED — they're provided by the
     final freestanding link)
  2. zig build-exe (full -M module list from build-native.sh,
     -Mprogram=koru/fb/tests/output_emitted.zig) -> m0.elf
     Command is in shell history; simplest: run build-native.sh's
     zig line verbatim with those two substitutions.

Artifacts:
- session/m0-i915/m0.elf (2.3MB ELF64, builds CLEAN — zero errors)
- koru-m0-i915.iso (14MB) at repo ROOT — isotree boot/koru.elf +
  grub.cfg (gfxterm 1920x1080x32 + serial + multiboot2) ->
  docker koruos-amd64-img grub-mkrescue -> MBR patch applied:
  byte 0x1be=0x83, entry0 LBA=0x10 (verified: boot=0x83 type=0xee
  lba=16 sectors=27679)
- Flash: dd koru-m0-i915.iso to SD -> T590 boots GRUB -> kernel ->
  i915.init() runs staged modeset on the SAME phys buffer GRUB
  adopted (GTT maps fb phys pages 0..N + 128 dummy).

Serial oracle markers (in order): "i915: ==== M0 static modeset
begin ====", fb geometry, pci dev+variant (ULT/ULX/DESKTOP), BAR0,
panel pp sequencer, legacy vga off, power+clocks, port detect,
ddi initialize (iboost), rawclk, gtt mapped N pages, pattern
filled, panel powered, link bw/lanes, pll hint, trainDP CR/EQ
PASS|FAIL, MODESET DONE. First missing marker = failure stage.

Known unverified-on-HW risks (in order of likelihood):
1. T590 CPU variant guess — detectCpu classifies by device ID at
   runtime; if it lands ULT the KBL_U BUF_TRANS table + iboost=3
   apply. Serial prints the variant — check first.
2. AUX may need PW_DDI_A on before DPCD reads — power.initialize
   should cover; if readCaps fails -> "FAIL link setting (AUX/DPCD)".
3. DPLL0 reuse vs configurable alloc — pll.alloc handles; if wrong
   PLL the panel stays dark but serial shows hint value.
4. Transcoder timing/M-N — ported verbatim; wrong values = garbage
   or sync-loss pattern, not silence (backlight already on).
5. PLANE_STRIDE=FB_Pitch(=bytes/64 for Linear) — ported verbatim
   from pipe_setup; if the panel shows skewed/striped image this
   is suspect #1 (SKL stride reg may want bytes).
6. eDP panel power sequencing delays — panel.zig uses libgfxinit
   defaults (210ms up etc.); panel.on() runs inside
   preferredLinkSetting BEFORE caps read.
7. fillPattern borrows GRUB's fb — if VBE gave non-1920x1080 or
   pitch<7680 the init refuses loudly ("fb too small").

Next: user flashes koru-m0-i915.iso, reports screen + serial tail.
If panel lights with pattern -> M0 DONE, move to M1 (real buffer
alloc + console composite). If dark -> last serial marker names
the stage; NOTES.md has per-stage register dumps available via
mmio.dumpReg if needed.

## HW REPORT #1 -> DIAG BUILD (2026-11-07)

T590 flash #1: backlight flashed ~2-3x in bursts, NO content, then
dark. Interpretation: panel power-on self-test blips + failure before
backlightOn (which would hold steady) OR post-MODESET-DONE link loss.
Serial was UART-only — user has NO serial adapter, markers invisible.

DIAG BUILD shipped (koru-m0-i915.iso rebuilt, same MBR patch):
- mmio.zig: textHook mirror — every say/sayDec/sayHex also renders
  into fb_base via text.zig 8x8 font (putc maps \n). ALL markers
  now on-screen, incl. FAIL paths + training output.
- i915.zig: text.init() after scanout; hook armed before first stage.
- legacyVgaOff() MOVED: was mid-init (killed VBE -> black gap), now
  inside enableOutput immediately before pipe.on — stage text stays
  visible on VBE through the whole init, handoff to GPU scanout is
  seamless (same phys buffer).
- panel.backlightOn() called EARLY (right after panel powered) for
  diag coverage — backlight stays lit through training; every stage
  renders on the lit panel. Original late call kept (idempotent).
- fillPattern skips top 176px band reserved for stage text.

Expected screen now: stage lines march down over dark background
during init (VBE path), then pattern+text once GPU takes over. Last
visible line = exact failure stage. SUCCESS = "MODESET DONE" +
shell console through GPU scanout.

## FILE HYGIENE RULING (Lars, 2026-11-07)

ONE canonical flashable ISO: session/m0-i915/FLASH-LATEST.iso —
always overwritten with the newest build; the ONLY file the user
flashes. iso-out/ is build scratch (timestamped ok). NEVER write
.iso to repo root, NEVER leave stale copies at predictable paths,
always refresh FLASH-LATEST.iso last. Current diag2 build is there.

## DIAG3 (2026-11-07) — ROOT CAUSE CANDIDATE + HALT-ON-FAULT

HW report diag2: zero on-screen markers, backlight cadence, return
to GRUB. Analysis: (a) markers can't survive reset — GRUB redraws;
(b) KERNEL ALIVE absent => crash before/at ~50ms window OR text path
dead. ROOT CAUSE FOUND in review: i915/mmio.zig setBase did
@ptrFromInt(bar0) WITHOUT hostmmio.map() — BAR0 was never in the
kernel page tables. First MMIO access (pll.initialize) -> #PF ->
no IDT -> triple fault -> reset -> GRUB. Timing fits "too fast to
see" exactly.

Fixes in diag3:
- i915/mmio.zig setBase now maps BAR0 16MiB via host mmio.map
  (identity VA==PA, 2MiB pages) before dereferencing. GTT at
  +0x800000 covered.
- NEW koru/native/faults.zig: full IDT (vectors 0-21 minus NMI)
  installed at kmain top. Asm stubs -> isrReport prints vec (+CR2
  for #PF) to serial AND fb text, then cli+hlt FOREVER. A crash
  now FREEZES with the report visible instead of wiping to GRUB.
- boot.zig: pub fn panic -> same freeze-with-report for Zig safety
  traps (@intCast/bounds/overflow in ReleaseSafe).
- 500ms dwell after KERNEL ALIVE so the beacon is readable before
  i915 touches hardware.

Expected diag3 outcomes:
- Screen freezes on "!! EXCEPTION vec=N" or "!! PANIC" -> crash
  localised; vec14+CR2 names the faulting address (expect BAR0
  region if map still wrong, or a bad pointer elsewhere).
- KERNEL ALIVE + i915 stage lines march -> modeset proceeds; last
  line = stage; MODESET DONE = success path reached.
- Still GRUB-loop with NO freeze -> fault is outside IDT coverage
  (MCE #MC vec18 IS covered; NMI vec2 deliberately not) or crash
  precedes faults.install() (trampoline/pmm — proven path).

## DIAG4 (2026-11-07) — LED BEACON CHANNEL (display-independent)

HW report diag3: identical — no markers, no freeze, backlight cycles,
return-to-GRUB. Conclusion: display path dies before/at i915 init
(probably power.initialize or earlier MMIO kills legacy scanout) so
fb_base text is invisible past that point; and no exception reached
the IDT (else isrReport would have frozen the machine — GRUB return
means either hang-not-fault, pre-IDT fault, or MCE/NMI class).

NEW: koru/native/led.zig — 8042 keyboard-LED channel, survives any
display state. Protocol:
  num (0x02)   = kernel alive — latched right after KERNEL ALIVE
  caps (0x04)  = blinks ~120ms per i915 stage() marker (all FAIL
                paths converted to stage() so they blink too)
  scroll(0x01) = latched at MODESET DONE (num+scroll solid)
  0x07 all     = exception/panic freeze (isrReport + panic call
                led.crash() first)
User report = which LEDs lit + caps blink count = exact stage.
Stage order for blink-count mapping is the sequence of stage()
calls in i915.zig init()/enableOutput() — ~16 markers.

## DIAG5 (2026-11-07) — SHELL-GATED i915 (proven-console-first)

HW report diag4: T590 keyboard LEDs don't physically drive (EC ACKs
but no light) + no PC speaker — LED/beeper channels dead. All
display-independent outputs exhausted except storage, which does NOT
exist for real HW (virtio only, QEMU; no AHCI/NVMe/SDHCI drivers).

DIAG5: i915 no longer auto-runs. boot.zig restored to fb.init ->
consoleMode -> shell.run() (the PROVEN console). shell.zig gained an
'i915' command — user types it at the live prompt; i915drv.init()
then runs with the WORKING console as the oracle:
- console alive + stage lines + 'i915 returned' = modeset path
  completed or failed gracefully, display survived.
- console freezes mid-stage = crash/hang at that stage (last line).
- console dies at a specific stage = display stolen there.
- '!! EXCEPTION/PANIC' frozen line = vectored fault, vec+CR2 shown.
Stage text appends at the shell cursor (text.init skipped since
W!=0) — cumulative, never cleared. fillPattern still reserves top
176px band; it will overwrite shell text below when modeset runs —
expected.

## ISO NAMING (Lars, 2026-11-07 — supersedes FLASH-LATEST)

Each build gets a UNIQUE timestamped ISO:
session/m0-i915/dist/koru-m0-i915-<tag>-<yyyymmdd-hhmm>.iso
NEVER overwrite an existing dist ISO, NEVER write .iso outside
dist/, NEVER duplicate names across dirs. User Etchers the newest
file in dist/. Current: dist/koru-m0-i915-diag5-20261107-1242.iso
(shell-gated i915 build).

## DIAG6 (2026-11-07) — MB2 HEADER GUARANTEE + asm volatile sweep

CRITICAL self-correction: earlier "NO MB2 MAGIC" was a FALSE NEGATIVE —
searched 0x1BADB002 (multiboot1) not 0xE85250D6 (multiboot2). Whether
the comptime-asm .multiboot section survived zig 0.15.2 is unproven,
but 0.15.2 DID newly require 'asm volatile' on output-less function
asm (build broke until restored) — asm handling tightened, so DCE of
unreferenced comptime asm data is plausible. Regardless: mb2 header
now emitted as export var mb2_header linksection(".multiboot") —
verified bytes at .text start: magic/arch/len=48/checksum/fb-tag/
end-tag all correct. If earlier builds lacked the header, GRUB
rejected the kernel outright -> menu loop -> explains EVERYTHING
(no console, no markers, backlight=firmware, 'returns to bootloader').
Also: all function-level asm in boot.zig/faults.zig re-volatile'd.
