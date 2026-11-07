// koru/native i915 — M0 static modesetting top level.
// Ported from libgfxinit common/hw-gfx-gma.adb Initialize +
// Enable_Output/Update_Outputs (coreboot, GPL-2.0), reduced to:
//   Skylake/Kaby Lake gen9, Sunrise Point PCH, single eDP on DIGI_A,
//   fixed 1920x1080@60, linear dumb scanout buffer (borrowed linear FB).
//
// Every stage emits a staged serial marker so a blank panel can be
// localized to the last completed step.

const mmio = @import("mmio.zig");
const R = mmio.R;
const dp = @import("dp.zig");
const types = @import("types.zig");
const panel = @import("panel.zig");
const power = @import("power.zig");
const port_detect = @import("port_detect.zig");
const connector_info = @import("connector_info.zig");
const pll = @import("pll.zig");
const pipe = @import("pipe.zig");
const ddi = @import("ddi.zig");
const pci = @import("pci"); // module root — path import would double-claim the file
const pmm = @import("pmm");
const hostmmio = @import("mmio"); // native page-table mapper (identity VA==PA)
const fb = @import("../fb.zig");
const text = @import("../text.zig");
const led = @import("../led.zig");

fn diagLine(s: [*:0]const u8) void {
    text.puts(s); // putc maps '\n' -> newline; draws into the adopted fb
}
fn stage(comptime msg: [*:0]const u8) void {
    mmio.say(msg); mmio.say("\n");
    led.blink(); // caps LED — survives display death; count = stages passed
}

// ---- port I/O (VGA legacy shutdown) -----------------------------------------

fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
        : .{ .memory = true });
}
fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
        : .{ .memory = true });
}

// ---- device detection --------------------------------------------------------
// config.ads.template Is_* masks. Gen=Skylake covers SKL/KBL/CFL/AML.
fn isKabyLakeU(id: u16) bool {
    return (id & 0xffcd) == 0x5901 or (id & 0xffce) == 0x5906;
}
fn isKabyLakeY(id: u16) bool {
    return (id & 0xffcf) == 0x5905 or (id & 0xffcf) == 0x590e;
}
fn isKabyLake(id: u16) bool {
    return (id & 0xffc7) == 0x5902 or
        (id & 0xffcf) == 0x5908 or
        (id & 0xffcf) == 0x590b or
        (id & 0xffcf) == 0x590d;
}
fn isCoffeeLakeU(id: u16) bool {
    return (id & 0xfff0) == 0x3ea0; // includes Whiskey Lake (T590 refresh)
}
fn isCoffeeLake(id: u16) bool {
    return (id & 0xfff0) == 0x3e90;
}
fn isSkylake(id: u16) bool {
    return (id & 0xffc7) == 0x1902 or
        (id & 0xffcf) == 0x190b or
        (id & 0xffcf) == 0x190d or
        (id & 0xffcf) == 0x190e or
        (id & 0xffcf) == 0x1905 or
        (id & 0xffcf) == 0x190e;
}

fn compatibleGpu(id: u16) bool {
    return isSkylake(id) or isKabyLake(id) or isKabyLakeU(id) or
        isKabyLakeY(id) or isCoffeeLake(id) or isCoffeeLakeU(id);
}

// Detect_CPU reduced: sets ddi.cpuVar / lastDigitalPort / iboost.
// Is_LP = ULT or ULX -> Has_DDI_D/E false -> Last_Digital_Port=DIGI_C.
fn detectCpu(id: u16) bool {
    const kbl = isKabyLake(id) or isKabyLakeU(id) or isKabyLakeY(id);
    const cfl = isCoffeeLake(id) or isCoffeeLakeU(id);
    if (!isSkylake(id) and !kbl and !cfl) return false;

    if (isKabyLakeU(id) or isCoffeeLakeU(id)) {
        ddi.cpuVar = .ult;
        ddi.lastDigitalPort = 2; // Is_LP -> DIGI_C
        ddi.iboost = 3;
    } else if (isKabyLakeY(id)) {
        ddi.cpuVar = .ulx;
        ddi.lastDigitalPort = 2;
        ddi.iboost = 3;
    } else {
        ddi.cpuVar = .desktop;
        ddi.lastDigitalPort = 4; // Has_DDI_E
        ddi.iboost = 1;
    }
    mmio.say("i915: gpu dev="); mmio.sayHex(id);
    mmio.say(" variant=");
    mmio.say(switch (ddi.cpuVar) {
        .ult => @as([*:0]const u8, "ULT"),
        .ulx => @as([*:0]const u8, "ULX"),
        .desktop => @as([*:0]const u8, "DESKTOP"),
    });
    mmio.say("\n");
    return true;
}

// pipe_setup.Legacy_VGA_Off: SR01 screen-off + VGACNTRL display disable.
fn legacyVgaOff() void {
    outb(0x3c4, 0x01); // VGA_SR_INDEX, VGA_SR01
    const sr1 = inb(0x3c5); // VGA_SR_DATA
    outb(0x3c5, sr1 | 0x20); // VGA_SR01_SCREEN_OFF = 1<<5
    mmio.sleepUs(100);
    mmio.setMask(R.CPU_VGACNTRL, 1 << 31); // VGA_CONTROL_VGA_DISPLAY_DISABLE
    mmio.say("i915: legacy vga off\n");
}

// ---- PCH RAWCLK ---------------------------------------------------------------

fn pchRawClkFreq(hz: u64) u32 {
    const mask: u32 = 0x3fff << 16;
    var v: u32 = @intCast((hz / 1_000_000) << 16);
    const fracK: u64 = (hz / 1000) % 1000;
    if (fracK != 0) {
        const dcr: u64 = (1000 + fracK / 2) / fracK; // Div_Round_Closest
        v |= @as(u32, @intCast(dcr - 1)) << 26;
    }
    return (mmio.rd(R.PCH_RAWCLK_FREQ) & ~mask) | (v & mask);
}

// ---- GTT setup for borrowed linear FB -----------------------------------------

fn setupGtt(fbPhys: u64, fbBytes: u64) void {
    const pages = (fbBytes + 4095) / 4096;
    var i: u64 = 0;
    while (i < pages) : (i += 1) {
        mmio.writeGtt(@intCast(i), fbPhys + i * 4096, true);
    }
    // +128 dummy pages (VT-d workaround) continuing phys addresses.
    i = 0;
    while (i < 128) : (i += 1) {
        mmio.writeGtt(@intCast(pages + i), fbPhys + (pages + i) * 4096, true);
    }
    mmio.say("i915: gtt mapped "); mmio.sayDec(pages);
    mmio.say(" pages +128 dummy\n");
}

// ---- fill test pattern into the borrowed buffer -------------------------------

fn fillPattern(phys: u64, pitch: u32, w: u32, h: u32) void {
    const px: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(phys)));
    const row = pitch / 4;
    var y: u32 = 176; // top band reserved for on-screen stage readout
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const border = x < 8 or y < 8 or x >= w - 8 or y >= h - 8;
            const checker = ((x / 32) + (y / 32)) % 2 == 0;
            px[y * row + x] = if (border) 0x00FF00FF else if (checker) 0x003366CC else 0x001A1A2E;
        }
    }
    stage("i915: pattern filled");
}

// ---- Enable_Output (gma.adb) ----------------------------------------------------

fn dumpReg(comptime name: [*:0]const u8, off: u32) void {
    mmio.say("  "); mmio.say(name); mmio.say("=");
    mmio.sayHex(mmio.rd(off)); mmio.say("\n");
}
fn dumpDisplayRegs() void {
    mmio.say("i915: regs:\n");
    dumpReg("DPLL_CTRL1", R.DPLL_CTRL1);
    dumpReg("DPLL_CTRL2", R.DPLL_CTRL2);
    dumpReg("DDI_BUF_CTL_A", R.DDI_BUF_CTL_A);
    dumpReg("DDI_AUX_CTL_A", R.DDI_AUX_CTL_A);
    dumpReg("DP_TP_CTL_A", R.DP_TP_CTL_A);
    dumpReg("PIPE_EDP_CONF", R.PIPE_EDP_CONF);
    dumpReg("PIPE_EDP_DDI_FUNC_CTL", R.PIPE_EDP_DDI_FUNC_CTL);
    dumpReg("DSPACNTR[A]", R.DSPACNTR);
    dumpReg("DSPASURF[A]", R.DSPASURF);
    dumpReg("DSPASTRIDE[A]", R.DSPASTRIDE);
    dumpReg("DSPALINOFF[A]", R.DSPALINOFF);
    dumpReg("DSPATILEOFF[A]", R.DSPATILEOFF);
    dumpReg("PLANE_SIZE_1_A", R.PLANE_SIZE_1_A);
    dumpReg("PLANE_POS_1_A", R.PLANE_POS_1_A);
    dumpReg("PCH_PP_STATUS", R.PCH_PP_STATUS);
    dumpReg("PCH_PP_CONTROL", R.PCH_PP_CONTROL);
    dumpReg("CDCLK_CTL", R.CDCLK_CTL);
    const pte = mmio.readGtt(0);
    mmio.say("  gtt[0] phys="); mmio.sayHex(pte.phys);
    mmio.say(" valid="); mmio.say(mmio.yn(pte.valid)); mmio.say("\n");
}

fn enableOutput(cfg: *types.Port_Config) bool {
    // Power_Up(Port): eDP panel power via PP sequence + DDI power domain.
    if (!power.powerUpEdp()) {
        stage("i915: FAIL powerUpEdp");
        return false;
    }
    stage("i915: panel powered");

    // Connector_Info.Preferred_Link_Setting: panel.on (PP VDD) +
    // DPCD caps + eDP rates + link pick.
    if (!connector_info.preferredLinkSetting(cfg.mode, &cfg.dp)) {
        stage("i915: FAIL link setting (AUX/DPCD)");
        return false;
    }
    mmio.say("i915: link bw="); mmio.sayDec(@intFromEnum(cfg.dp.bandwidth));
    mmio.say(" lanes="); mmio.sayDec(dp.laneCountInt(cfg.dp.laneCount));
    mmio.say("\n");
    // Bandwidth sufficiency: need = pxclk*bpp*10/8; avail = symHz*lanes*8/10.
    // symHz uses the spec table (1.62/2.7/5.4GHz) — dp.symbolRate is
    // printed raw too: it returns 162e6 for b1_62, 10x under spec.
    const needBps = cfg.mode.dotclock * @as(u64, @intCast(cfg.mode.bpc)) * 3 * 10 / 8;
    const symHz: u64 = switch (cfg.dp.bandwidth) {
        .b1_62 => 1_620_000_000, .b2_7 => 2_700_000_000, .b5_4 => 5_400_000_000,
    };
    const availBps = symHz * dp.laneCountInt(cfg.dp.laneCount) * 8 / 10;
    mmio.say("i915: need="); mmio.sayDec(needBps / 1_000_000);
    mmio.say("Mbps avail="); mmio.sayDec(availBps / 1_000_000);
    mmio.say("Mbps symFn="); mmio.sayDec(dp.symbolRate(cfg.dp.bandwidth));
    mmio.say(if (availBps >= needBps) " OK\n" else " INSUFFICIENT\n");

    const pr = pll.alloc(cfg);
    if (!pr.ok) {
        stage("i915: FAIL pll alloc");
        return false;
    }
    const pllHint = pll.pllRegValue(pr.pll);
    mmio.say("i915: pll="); mmio.sayDec(@intFromEnum(pr.pll));
    mmio.say(" hint="); mmio.sayDec(pllHint); mmio.say("\n");

    var success = false;
    var attempt: usize = 0;
    while (attempt < 2 and !success) : (attempt += 1) {
        port_detect.clearHotplug();
        if (!ddi.preOn(cfg.dp, pllHint)) {
            stage("i915: trainDP failed, try link fallback");
            if (attempt == 0 and connector_info.nextLinkSetting(&cfg.dp, cfg.mode)) continue;
            break;
        }
        legacyVgaOff();
        pipe.on(&cfg.fb, &cfg.mode, &cfg.dp);
        panel.backlightOn();
        success = true;
    }
    dumpDisplayRegs();
    if (!success) {
        panel.off();
        pll.free(pr.pll);
        stage("i915: FAIL modeset sequence");
        return false;
    }
    stage("i915: MODESET DONE — eDP should be lit");
    return true;
}

// ---- public init ----------------------------------------------------------------

pub fn init() void {

    // Borrow the adopted linear framebuffer.
    const s = fb.scanout() orelse {
        stage("i915: FAIL no linear fb (vgpu/mb2 missing)");
        return;
    };
    if (text.dims().w == 0) text.init(); // boot.zig may have drawn the beacon already
    text.setColor(0xFFFFFFFF, 0xFF202040);
    mmio.textHook = diagLine;
    led.set(0x02); // num = kernel+i915 alive latch
    stage("i915: ==== M0 static modeset begin ====");
    stage("i915: fb phys=");
    mmio.sayHex(s.phys);
    mmio.say(" pitch="); mmio.sayDec(s.pitch);
    mmio.say(" "); mmio.sayDec(s.w); mmio.say("x"); mmio.sayDec(s.h); mmio.say("\n");

    // PCI: find the Intel VGA device (class 0x03/0x00, vendor 0x8086).
    if (pci.count == 0) pci.init();
    const dev = pci.findClass(0x03, 0x00) orelse {
        stage("i915: FAIL no VGA-class device");
        return;
    };
    if (dev.vendor != 0x8086 or !compatibleGpu(dev.device)) {
        mmio.say("i915: FAIL gpu vendor/device ");
        mmio.sayHex(dev.vendor); mmio.say(":"); mmio.sayHex(dev.device);
        mmio.say("\n");
        return;
    }
    mmio.say("i915: pci dev "); mmio.sayHex(dev.device); mmio.say("\n");
    if (!detectCpu(dev.device)) {
        stage("i915: FAIL device not gen9 skylake-family");
        return;
    }

    const bar0 = pci.barPhys(dev, 0);
    if (bar0 == 0) {
        stage("i915: FAIL BAR0 unmapped");
        return;
    }
    mmio.setBase(bar0, bar0 + 0x80_0000);
    // memory space + bus master
    pci.setCommand(dev, pci.command(dev) | 0x6);
    mmio.say("i915: BAR0 mapped\n");

    pll.initialize();
    panel.staticInit();
    panel.setupPPSequencer(true);
    stage("i915: panel pp sequencer done");

    ddi.postResetOff();

    if (!power.initialize()) {
        stage("i915: FAIL power/clocks init");
        return;
    }
    stage("i915: power+clocks up");

    port_detect.initialize();
    stage("i915: port detect done");

    ddi.initialize();

    mmio.wr(R.PCH_RAWCLK_FREQ, pchRawClkFreq(power.getRawClock()));
    stage("i915: rawclk written");

    // Modeset: fixed 1080p60, borrow the linear FB as scanout.
    var mode = dp.M1920x1080_60;
    mode.bpc = connector_info.defaultBpc(); // eDP -> 6bpc
    _ = power.limitDotclocks(mode.dotclock);
    _ = power.updateCdClk(mode.dotclock);

    var surf = s; // borrowed linear fb — swapped for a real alloc if too small
    if (surf.pitch / 4 < 1920 or surf.h < 1080) {
        // GRUB handed us <1080p (mb2 header asks 1024x768) — allocate the
        // scanout for real. 2025 frames = 8294400B = 1920*1080*4.
        // align_frames 512 = 2MiB leaf alignment, 1 = any page.
        const need: u64 = 1920 * 1080 * 4;
        const frames: usize = @intCast((need + 4095) / 4096);
        const alloc = pmm.allocContiguous(frames, 512) orelse
            pmm.allocContiguous(frames, 1) orelse {
            stage("i915: FAIL fb too small + scanout alloc failed");
            return;
        };
        if (!hostmmio.map(alloc, need)) {
            stage("i915: FAIL scanout alloc unmapped");
            return;
        }
        stage("i915: scanout alloc=");
        mmio.sayHex(alloc);
        mmio.say("\n");
        surf = .{ .phys = alloc, .pitch = 1920 * 4, .w = 1920, .h = 1080 };
    }
    const stridePx = surf.pitch / 4;
    var cfg = types.Port_Config{
        .port = .DIGI_A,
        .display = .DP,
        .panel = 1,
        .mode = mode,
        .fb = .{
            .offset = 0,
            .width = 1920,
            .height = 1080,
            .stride = stridePx,
            .vstride = 1080,
            .bpc = 8,
        },
    };
    _ = &cfg;

    setupGtt(surf.phys, @as(u64, stridePx) * 4 * 1080);
    fillPattern(surf.phys, surf.pitch, surf.w, surf.h);

    if (!enableOutput(&cfg)) return;
    stage("i915: ==== M0 modeset complete ====");
}
