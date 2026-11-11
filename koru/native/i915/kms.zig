// koru/native i915/kms — M1 dumb-KMS milestone.
//
// Minimal KMS object model over the proven gen9 register-init path:
//   PCI probe -> Device { crtcs, planes, connectors } -> dumb buffer
//   create/map (pmm frames -> GTT PTEs -> identity CPU map) -> modeset
//   -> first pixels written through the buffer's CPU mapping, console
//   rebased onto it.
//
// What changed vs M0 (i915.zig): the framebuffer is no longer borrowed
// from GRUB's VBE surface or allocated ad-hoc inside init — it is a
// DumbBuffer object owned by the device, tracked by handle, mapped into
// the GTT at a device-owned page offset, and referenced by the plane
// through the object model. Modeset takes (connector, crtc, mode,
// buffer) instead of a one-shot Port_Config literal.
//
// The register-level sequence is the SAME proven libgfxinit port the M0
// path uses — power wells, DPLL/CDCLK, AUX/DPCD, link training, pipe/
// transcoder/plane programming are all reused, not re-derived. Only the
// object plumbing and buffer ownership are new.
//
// Stage markers: every step emits a staged marker (serial + fb text +
// UDP "KORU kms: ..." + caps-LED blink) so a blank panel localises to
// the last completed step, same oracle discipline as M0.

const std = @import("std");
const mmio = @import("mmio.zig"); // i915 reg + GTT layer
const R = mmio.R;
const hostmmio = @import("mmio"); // host page-table mapper (identity VA==PA)
const pci = @import("pci"); // module root
const ioapic = @import("ioapic"); // module root
const acpi = @import("acpi"); // module root
const pmm = @import("pmm"); // module root
const net = @import("net"); // module root
const dp = @import("dp.zig");
const types = @import("types.zig");
const power = @import("power.zig");
const port_detect = @import("port_detect.zig");
const connector_info = @import("connector_info.zig");
const pll = @import("pll.zig");
const pipe = @import("pipe.zig");
const ddi = @import("ddi.zig");
const panel = @import("panel.zig");
const m0 = @import("i915.zig"); // proven M0 helpers, promoted pub for M1
const fb = @import("../fb.zig");
const text = @import("../text.zig");
const led = @import("../led.zig");

// ---- stage markers ---------------------------------------------------------

fn stage(comptime msg: [*:0]const u8) void {
    mmio.say(msg); mmio.say("\n");
    net.mark(std.mem.sliceTo(msg, 0)); // UDP marker — survives display death
    led.blink(); // caps LED — survives display death; count = stages passed
}

// ---- KMS object model -------------------------------------------------------
// Simplified but real: objects carry identity, bindings, and state — the
// modeset path resolves them instead of hardcoding pipe/plane/port. One
// crtc (pipe A primary), two planes (hires DSP + sprite), one connector
// (eDP on DIGI_A). That is the whole T590 eDP path; B/C pipes and the
// DP/HDMI connectors exist in hardware but are out of M1 scope.

pub const ConnectorKind = enum { None, eDP, DP, HDMI, VGA_LVDS };

pub const Connector = struct {
    id: u32 = 0,
    kind: ConnectorKind = .None,
    port: types.GPU_Port = .DIGI_A,
    modes: []const dp.Mode = &.{},
    dp: dp.DPLink = .{}, // receiver caps + chosen link settings
    mode: ?dp.Mode = null, // current modeset mode (bpc applied)
    crtc_id: ?u32 = null, // bound crtc once enabled
    enabled: bool = false,
};

pub const Plane = struct {
    id: u32 = 0,
    pipe: types.Pipe = .Primary,
    primary: bool = false, // true = hires DSP plane (DSPA*), false = sprite
    crtc_id: ?u32 = null,
    fb: ?DumbBuffer = null, // scanned buffer (handle table entry copied in)
    enabled: bool = false,
};

pub const Crtc = struct {
    id: u32 = 0,
    pipe: types.Pipe = .Primary,
    mode: ?dp.Mode = null,
    active: bool = false,
};

pub const DumbBuffer = struct {
    handle: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0, // bytes per row
    bpp: u32 = 32, // XRGB8888 only for M1
    size: u64 = 0, // total bytes
    phys: u64 = 0, // contiguous phys base (pmm)
    gtt_page: u32 = 0, // first PTE index in the GTT aperture
    gtt_offset: u64 = 0, // byte offset into aperture == gtt_page*4096 (DSPSURF)
    frames: usize = 0, // pmm frames held
    map: ?[*]volatile u32 = null, // CPU view — identity VA == phys
};

pub const MAX_DUMBS: usize = 16; // scene swapchain(2) + modeset + window dmabufs + diagnostics
pub const DUMMY_GTT_PAGES: u32 = 128; // libgfxinit VT-d tail, same as M0

pub const Device = struct {
    pdev: pci.Device = undefined,
    bar0: u64 = 0,
    up: bool = false,
    gtt_next: u32 = 0, // next free GTT page index (bump allocator)
    mode: ?dp.Mode = null, // committed modeset mode
    pll: ?pll.PLL = null, // PLL held by the active modeset
    scanout: ?u32 = null, // dumb handle currently scanned out
    dumbs: [MAX_DUMBS]?DumbBuffer = @splat(null),
    crtcs: [1]Crtc = @splat(.{}),
    planes: [2]Plane = @splat(.{}),
    connectors: [1]Connector = @splat(.{}),
};

var gdev: Device = .{};
pub fn device() *Device {
    return &gdev;
}

// ---- probe + device init -----------------------------------------------------
// Same register-init order as M0 i915.init, minus the fb borrow and the
// fixed-1080p modeset: the device comes up with clocks/power/ports live
// and an object model populated, ready for dumb-create + modeset calls.

pub fn probe() bool {
    if (gdev.up) return true;
    stage("kms: ==== M1 dumb-KMS begin ====");

    // PCI: find the Intel VGA device (class 0x03/0x00, vendor 0x8086).
    if (pci.count == 0) pci.init();
    const d = pci.findClass(0x03, 0x00) orelse {
        stage("kms: FAIL no VGA-class device");
        return false;
    };
    if (d.vendor != 0x8086 or !m0.compatibleGpu(d.device)) {
        mmio.say("kms: FAIL gpu vendor/device ");
        mmio.sayHex(d.vendor); mmio.say(":"); mmio.sayHex(d.device);
        mmio.say("\n");
        return false;
    }
    mmio.say("kms: pci dev "); mmio.sayHex(d.device); mmio.say("\n");
    if (!m0.detectCpu(d.device)) {
        stage("kms: FAIL device not gen9 skylake-family");
        return false;
    }
    gdev.pdev = d.*;

    const bar0 = pci.barPhys(d, 0);
    if (bar0 == 0) {
        stage("kms: FAIL BAR0 unmapped");
        return false;
    }
    mmio.setBase(bar0, bar0 + 0x80_0000);
    // memory space + bus master
    pci.setCommand(d, pci.command(d) | 0x6);
    gdev.bar0 = bar0;
    mmio.say("kms: BAR0 mapped\n");
    stage("kms: pci probe done");

    pll.initialize();
    panel.staticInit();
    panel.setupPPSequencer(true);
    stage("kms: panel pp sequencer done");

    ddi.postResetOff();

    if (!power.initialize()) {
        stage("kms: FAIL power/clocks init");
        return false;
    }
    stage("kms: power+clocks up");

    port_detect.initialize();
    stage("kms: port detect done");

    ddi.initialize();

    mmio.wr(R.PCH_RAWCLK_FREQ, m0.pchRawClkFreq(power.getRawClock()));
    stage("kms: rawclk written");

    // Populate the object model. Single-pipe eDP bring-up: one crtc,
    // the hires plane + sprite plane on pipe A, one eDP connector.
    gdev.crtcs[0] = .{ .id = 0, .pipe = .Primary };
    gdev.planes[0] = .{ .id = 0, .pipe = .Primary, .primary = true };
    gdev.planes[1] = .{ .id = 1, .pipe = .Primary, .primary = false };
    gdev.connectors[0] = .{
        .id = 0,
        .kind = .eDP,
        .port = .DIGI_A,
        .modes = &.{dp.M1920x1080_60}, // EDID/DDC not ported — native mode only
    };
    stage("kms: object model populated (1 crtc, 2 planes, 1 eDP)");
    gdev.up = true;
    return true;
}

// ---- dumb buffers -------------------------------------------------------------
// drm_mode_create_dumb equivalent: contiguous physical frames (pmm) ->
// GTT PTEs at the device's bump offset -> identity CPU mapping. The
// scanout engine reads through the GTT; the CPU writes through the
// identity map. pitch is padded to 64B (the SKL stride granularity).

fn align64(v: u32) u32 {
    return (v + 63) & ~@as(u32, 63);
}

pub fn dumbCreate(w: u32, h: u32, bpp: u32) ?u32 {
    if (!gdev.up) {
        mmio.say("kms: dumbCreate refused — device not up\n");
        return null;
    }
    if (bpp != 32) {
        mmio.say("kms: dumbCreate refused — bpp "); mmio.sayDec(bpp);
        mmio.say(" (XRGB8888 only)\n");
        return null;
    }
    if (w == 0 or h == 0 or w > 4096 or h > 4096) {
        mmio.say("kms: dumbCreate refused — bad dims ");
        mmio.sayDec(w); mmio.say("x"); mmio.sayDec(h); mmio.say("\n");
        return null;
    }
    var slot: ?usize = null;
    var si: usize = 0;
    while (si < gdev.dumbs.len) : (si += 1) {
        if (gdev.dumbs[si] == null) {
            slot = si;
            break;
        }
    }
    const s = slot orelse {
        mmio.say("kms: dumbCreate refused — handle table full\n");
        return null;
    };

    const pitch = align64(w * 4);
    const size = @as(u64, pitch) * h;
    const frames64 = (size + 4095) / 4096;
    const frames: usize = @intCast(frames64);
    const phys = pmm.allocContiguous(frames, 1) orelse {
        stage("kms: FAIL dumb alloc (no contiguous frames)");
        return null;
    };
    if (!hostmmio.map(phys, size)) {
        _ = pmm.freeBlock(phys, frames);
        stage("kms: FAIL dumb alloc unmapped");
        return null;
    }

    // GTT: PTEs for the buffer's pages, then the +128 dummy tail.
    // Dummies alias the buffer's LAST page — M0 mapped continuing phys
    // (unallocated RAM past the alloc); aliasing a live page is strictly
    // safer and equally satisfies the VT-d prefetch tail.
    const gtt_page = gdev.gtt_next;
    var i: u64 = 0;
    while (i < frames64) : (i += 1) {
        mmio.writeGtt(gtt_page + @as(u32, @intCast(i)), phys + i * 4096, true);
    }
    const lastPhys = phys + (frames64 - 1) * 4096;
    var di: u32 = 0;
    while (di < DUMMY_GTT_PAGES) : (di += 1) {
        mmio.writeGtt(gtt_page + @as(u32, @intCast(frames64)) + di, lastPhys, true);
    }
    gdev.gtt_next += @as(u32, @intCast(frames64 + DUMMY_GTT_PAGES));

    const buf = DumbBuffer{
        .handle = @intCast(s),
        .width = w,
        .height = h,
        .pitch = pitch,
        .bpp = bpp,
        .size = size,
        .phys = phys,
        .gtt_page = gtt_page,
        .gtt_offset = @as(u64, gtt_page) * 4096,
        .frames = frames,
        .map = @ptrFromInt(@as(usize, @intCast(phys))),
    };
    gdev.dumbs[s] = buf;
    mmio.say("kms: dumb h="); mmio.sayDec(buf.handle);
    mmio.say(" phys="); mmio.sayHex(phys);
    mmio.say(" gtt_page="); mmio.sayDec(gtt_page);
    mmio.say(" off="); mmio.sayHex(buf.gtt_offset);
    mmio.say(" frames="); mmio.sayDec(frames64);
    mmio.say(" pitch="); mmio.sayDec(pitch); mmio.say("\n");
    stage("kms: dumb buffer created+mapped");
    return buf.handle;
}

pub fn dumbDestroy(handle: u32) bool {
    if (handle >= gdev.dumbs.len) return false;
    const buf = gdev.dumbs[handle] orelse return false;
    if (gdev.scanout == handle) {
        mmio.say("kms: dumbDestroy refused — handle is the scanout\n");
        return false;
    }
    var i: u32 = 0;
    const nframes = @as(u32, @intCast(buf.frames));
    while (i < nframes) : (i += 1) {
        mmio.writeGtt(buf.gtt_page + i, 0, false);
    }
    i = 0;
    while (i < DUMMY_GTT_PAGES) : (i += 1) {
        mmio.writeGtt(buf.gtt_page + nframes + i, 0, false);
    }
    _ = pmm.freeBlock(buf.phys, buf.frames);
    gdev.dumbs[handle] = null;
    stage("kms: dumb buffer destroyed");
    return true;
}

pub fn dumbGet(handle: u32) ?*const DumbBuffer {
    if (handle >= gdev.dumbs.len) return null;
    return if (gdev.dumbs[handle]) |*b| b else null;
}

// ---- GTT page allocator for non-dumb GPU consumers -------------------------
// gpublt.zig's persistent ring/fence and comp layer-backing mappings share
// the SAME gtt_next bump as dumbCreate — one allocator, no collisions.
// gt.zig's probe owns fixed slots at GTT_BASE_SLOT=0x8000 (page 32768);
// every bump allocation must stay below that or it would overwrite the
// probe's ring/hwsp/proof PTEs.
pub const GTT_SAFE_LIMIT: u32 = 0x8000;

// gttAlloc — reserve `pages` GTT aperture pages (+ the DUMMY_GTT_PAGES
// VT-d prefetch tail, same convention as dumbCreate). Returns the first
// page index or null when the aperture budget is spent.
pub fn gttAlloc(pages: u32) ?u32 {
    if (!gdev.up) return null;
    if (pages == 0 or pages > GTT_SAFE_LIMIT) return null;
    const p = gdev.gtt_next;
    if (p + pages + DUMMY_GTT_PAGES > GTT_SAFE_LIMIT) {
        mmio.say("kms: gttAlloc refused — aperture budget ");
        mmio.sayDec(p);
        mmio.say("+"); mmio.sayDec(pages); mmio.say("\n");
        return null;
    }
    gdev.gtt_next += pages + DUMMY_GTT_PAGES;
    return p;
}

// gttMapPhys — write PTEs for `nPages` contiguous phys pages starting at
// GTT page `firstPage`, then the dummy tail aliasing the last page.
// Caller owns the phys lifetime (pmm block must outlive the mapping).
pub fn gttMapPhys(firstPage: u32, phys: u64, nPages: u64) void {
    var i: u64 = 0;
    while (i < nPages) : (i += 1) {
        mmio.writeGtt(firstPage + @as(u32, @intCast(i)), phys + i * 4096, true);
    }
    if (nPages == 0) return;
    const lastPhys = phys + (nPages - 1) * 4096;
    var d: u32 = 0;
    while (d < DUMMY_GTT_PAGES) : (d += 1) {
        mmio.writeGtt(firstPage + @as(u32, @intCast(nPages)) + d, lastPhys, true);
    }
}

// ---- test pattern ---------------------------------------------------------------
// Written through the dumb buffer's CPU mapping — the "first pixels" of
// the M1 path. Deliberately unlike the M0 checkerboard: eight vertical
// colour bars over a dark field with a yellow frame and a checker strip,
// so a HW photo unambiguously names the path that produced it.

fn fillTestPattern(buf: *const DumbBuffer) void {
    const px: [*]volatile u32 = buf.map.?;
    const row = buf.pitch / 4;
    const w = buf.width;
    const h = buf.height;
    const bars = [_]u32{
        0x00FF0000, // red
        0x0000FF00, // green
        0x000000FF, // blue
        0x00FFFF00, // yellow
        0x00FF00FF, // magenta
        0x0000FFFF, // cyan
        0x00FFFFFF, // white
        0x00808080, // grey
    };
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var c: u32 = 0x001A1A2E; // M0 dark bg — console cells blend in
            const framed = x < 8 or y < 8 or x >= w - 8 or y >= h - 8;
            if (framed) {
                c = 0x00FFFF00; // yellow frame
            } else if (y >= h - h / 4) {
                // bottom quarter: 16px checker, M0's two tones
                c = if (((x / 16) + (y / 16)) % 2 == 0) 0x003366CC else 0x001A1A2E;
            } else if (y >= 16) {
                const bar = @min(x * bars.len / w, bars.len - 1);
                c = bars[@intCast(bar)];
            }
            px[@as(usize, @intCast(y)) * @as(usize, @intCast(row)) +
                @as(usize, @intCast(x))] = c;
        }
    }
    mmio.say("kms: test pattern written via cpu map ");
    mmio.sayHex(@intFromPtr(px)); mmio.say("\n");
    stage("kms: test pattern filled");
}

// ---- modeset --------------------------------------------------------------------
// The M0 enableOutput sequence, driven by objects: connector supplies the
// DP link + port, crtc supplies the pipe, plane supplies the scanout
// registers, dumb buffer supplies fb geometry + GTT offset.

fn fbFromBuf(buf: *const DumbBuffer) types.Framebuffer {
    return .{
        .offset = buf.gtt_offset,
        .width = buf.width,
        .height = buf.height,
        .stride = buf.pitch / 4, // pixels per line
        .vstride = buf.height,
        .bpc = 8, // XRGB8888; mode.bpc=6 -> dither on, same as M0
        .tiling = .Linear,
    };
}

pub fn modeset(connHandle: u32, crtcHandle: u32, bufHandle: u32) bool {
    if (!gdev.up) {
        stage("kms: FAIL modeset — device not up");
        return false;
    }
    if (connHandle >= gdev.connectors.len or crtcHandle >= gdev.crtcs.len or
        bufHandle >= gdev.dumbs.len)
    {
        stage("kms: FAIL modeset — bad object handle");
        return false;
    }
    const conn = &gdev.connectors[connHandle];
    const crtc = &gdev.crtcs[crtcHandle];
    const buf = gdev.dumbs[bufHandle] orelse {
        stage("kms: FAIL modeset — null dumb buffer");
        return false;
    };
    if (conn.modes.len == 0) {
        stage("kms: FAIL modeset — connector has no modes");
        return false;
    }

    // Mode comes off the connector's mode list — the object-model way.
    // eDP default BPC (6) like M0; dither engages via fb.bpc=8.
    var mode = conn.modes[0];
    mode.bpc = connector_info.defaultBpc();
    _ = power.limitDotclocks(mode.dotclock);
    _ = power.updateCdClk(mode.dotclock);

    var cfg = types.Port_Config{
        .port = conn.port,
        .display = .DP,
        .panel = 1,
        .mode = mode,
        .pipe = crtc.pipe,
        .fb = fbFromBuf(&buf),
    };
    mmio.say("kms: modeset conn="); mmio.sayDec(conn.id);
    mmio.say(" kind="); mmio.say(switch (conn.kind) {
        .eDP => @as([*:0]const u8, "eDP"),
        .DP => @as([*:0]const u8, "DP"),
        .HDMI => @as([*:0]const u8, "HDMI"),
        .VGA_LVDS => @as([*:0]const u8, "VGA_LVDS"),
        .None => @as([*:0]const u8, "none"),
    });
    mmio.say(" crtc="); mmio.sayDec(crtc.id);
    mmio.say(" buf="); mmio.sayDec(buf.handle);
    mmio.say(" gtt_off="); mmio.sayHex(cfg.fb.offset); mmio.say("\n");
    stage("kms: modeset objects resolved");

    // Power_Up(Port): eDP panel power via PP sequence + DDI power domain.
    if (!power.powerUpEdp()) {
        stage("kms: FAIL powerUpEdp");
        return false;
    }
    stage("kms: panel powered");

    // Connector_Info.Preferred_Link_Setting: panel.on + DPCD caps +
    // eDP rates + link pick — all over the proven AUX channel.
    if (!connector_info.preferredLinkSetting(cfg.mode, &cfg.dp)) {
        stage("kms: FAIL link setting (AUX/DPCD)");
        return false;
    }
    conn.dp = cfg.dp; // receiver caps persist on the connector object
    mmio.say("kms: link bw="); mmio.sayDec(@intFromEnum(cfg.dp.bandwidth));
    mmio.say(" lanes="); mmio.sayDec(dp.laneCountInt(cfg.dp.laneCount));
    mmio.say("\n");
    // Bandwidth sufficiency: need = pxclk*bpp*10/8; avail = symHz*lanes*8/10.
    const needBps = cfg.mode.dotclock * @as(u64, @intCast(cfg.mode.bpc)) * 3 * 10 / 8;
    const symHz: u64 = switch (cfg.dp.bandwidth) {
        .b1_62 => 1_620_000_000, .b2_7 => 2_700_000_000, .b5_4 => 5_400_000_000,
    };
    const availBps = symHz * dp.laneCountInt(cfg.dp.laneCount) * 8 / 10;
    mmio.say("kms: need="); mmio.sayDec(needBps / 1_000_000);
    mmio.say("Mbps avail="); mmio.sayDec(availBps / 1_000_000);
    mmio.say("Mbps "); mmio.say(if (availBps >= needBps) "OK\n" else "INSUFFICIENT\n");
    stage("kms: link settings chosen");

    const pr = pll.alloc(&cfg);
    if (!pr.ok) {
        stage("kms: FAIL pll alloc");
        return false;
    }
    const pllHint = pll.pllRegValue(pr.pll);
    mmio.say("kms: pll="); mmio.sayDec(@intFromEnum(pr.pll));
    mmio.say(" hint="); mmio.sayDec(pllHint); mmio.say("\n");
    stage("kms: pll allocated");

    var success = false;
    var attempt: usize = 0;
    while (attempt < 2 and !success) : (attempt += 1) {
        port_detect.clearHotplug();
        if (!ddi.preOn(cfg.dp, pllHint)) {
            stage("kms: trainDP failed, try link fallback");
            if (attempt == 0 and connector_info.nextLinkSetting(&cfg.dp, cfg.mode)) continue;
            break;
        }
        stage("kms: link trained (CR+EQ pass)");
        m0.legacyVgaOff();
        pipe.on(&cfg.fb, &cfg.mode, &cfg.dp);
        stage("kms: pipe+plane programmed");
        panel.backlightOn();
        success = true;
    }
    m0.dumpDisplayRegs();
    if (!success) {
        panel.off();
        pll.free(pr.pll);
        stage("kms: FAIL modeset sequence");
        return false;
    }

    // Commit the object state — this is what makes it a modeset, not a
    // register poke: the connector/crtc/plane now name their bindings.
    conn.mode = cfg.mode;
    conn.crtc_id = crtc.id;
    conn.enabled = true;
    conn.dp = cfg.dp;
    crtc.mode = cfg.mode;
    crtc.active = true;
    gdev.planes[0].fb = buf;
    gdev.planes[0].crtc_id = crtc.id;
    gdev.planes[0].enabled = true;
    gdev.mode = cfg.mode;
    gdev.pll = pr.pll;
    gdev.scanout = bufHandle;
    stage("kms: MODESET DONE — eDP lit via dumb-KMS");
    return true;
}

// ---- console handoff --------------------------------------------------------------
// After modeset commits, repoint the fb seam + text console at the dumb
// buffer: console output becomes scanout content through the real KMS
// path (the M1 answer to M0's compositing gap). Only on success — a
// failed modeset leaves the console on the old fb untouched.

fn rebaseConsole(bufHandle: u32) void {
    const buf = gdev.dumbs[bufHandle] orelse return;
    fb.rebase(buf.phys, buf.pitch, buf.width, buf.height);
    text.syncDims();
    text.setColor(0xFFFFFFFF, 0x001A1A2E);
    stage("kms: console rebased onto dumb buffer");
}

// ---- public flows ------------------------------------------------------------------

// runBuffer: dumb create + CPU-map + pattern, NO modeset. Isolates the
// buffer path (pmm alloc, GTT PTEs, CPU writes) from the display path —
// 'kmsbuf' on the shell. Proves allocation/mapping without touching
// the panel.
pub fn runBuffer() void {
    stage("kms: ==== M1 dumb-buffer test ====");
    if (!probe()) return;
    const h = dumbCreate(1920, 1080, 32) orelse return;
    const buf = gdev.dumbs[h].?;
    fillTestPattern(&buf);
    // GTT readback: prove PTE[0] resolves to the buffer phys — the
    // phys->GTT->DSPSURF chain the plane will walk.
    const pte = mmio.readGtt(buf.gtt_page);
    mmio.say("kms: gtt["); mmio.sayDec(buf.gtt_page); mmio.say("] phys=");
    mmio.sayHex(pte.phys); mmio.say(" valid="); mmio.say(mmio.yn(pte.valid));
    mmio.say(" want="); mmio.sayHex(buf.phys); mmio.say("\n");
    stage("kms: buffer path done (no modeset — panel untouched)");
}

// runModeset: full M1 path — probe, dumb buffer, test pattern, modeset,
// console rebase. 'kms' on the shell. Re-runnable: each call allocates
// a fresh dumb buffer at the next GTT offset, so a second 'kms' also
// exercises the nonzero-DSPSURF path on hardware.
pub fn runModeset() void {
    stage("kms: ==== M1 dumb-KMS modeset ====");
    if (!probe()) return;

    // 1920x1080x32 — the panel's native mode; pitch lands on 7680B.
    const h = dumbCreate(1920, 1080, 32) orelse return;
    const buf = gdev.dumbs[h].?;
    fillTestPattern(&buf);

    const prev = gdev.scanout; // capture before modeset replaces it
    if (!modeset(0, 0, h)) {
        _ = dumbDestroy(h); // not scanout — free the handle for the next try
        return;
    }
    rebaseConsole(h);

    // Retire the previous scanout buffer if a re-run replaced it —
    // after the plane points at the new GTT offset and the console has
    // moved, the old frames are dead weight.
    if (prev) |p| {
        if (p != h) _ = dumbDestroy(p);
    }
    text.puts("KORU M1 dumb-KMS live\n");
    stage("kms: ==== M1 dumb-KMS complete ====");
}

// ---- M2 atomic commit + pageflip/vblank -------------------------------------
// The atomic model for a same-mode scanout swap: CHECK validates the
// candidate object, TEST stages it with zero hardware writes, COMMIT is a
// single surface-register write the display engine applies at vblank —
// the hardware performs the atomic commit, no modeset re-run, no blank.
// vblank events arrive on the display-engine IIR, polled (consoleMode has
// no IRQ path). Every step emits a stage marker so the panel/UDP names
// the last completed atomic step.

// Distinct flip pattern — horizontal bands + a white diagonal tick, so a
// photo unambiguously distinguishes a flipped frame from the M1 bars.
fn fillFlipPattern(buf: *const DumbBuffer) void {
    const px: [*]volatile u32 = buf.map.?;
    const row = buf.pitch / 4;
    const w = buf.width;
    const h = buf.height;
    const bands = [_]u32{ 0x0000FF00, 0x0000FFFF, 0x000000FF, 0x00FF00FF };
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const bi = @as(usize, @intCast(@min((y * 4) / h, 3)));
            var c: u32 = bands[bi];
            if (x == y or x + y == w - 1) c = 0x00FFFFFF; // diagonal tick
            if (x < 8 or y < 8 or x >= w - 8 or y >= h - 8) c = 0x00FFFF00;
            px[@as(usize, @intCast(y)) * @as(usize, @intCast(row)) +
                @as(usize, @intCast(x))] = c;
        }
    }
    stage("kms: flip pattern filled");
}

// CHECK: is this handle a legal flip candidate? Pure object validation —
// no register writes, safe to call speculatively.
pub fn atomicCheck(bufHandle: u32) bool {
    if (!gdev.up) return false;
    if (gdev.scanout == null) {
        mmio.say("kms: atomicCheck — no live scanout (run 'kms' first)\n");
        return false;
    }
    const buf = gdev.dumbs[bufHandle] orelse {
        mmio.say("kms: atomicCheck — null buffer\n");
        return false;
    };
    if (bufHandle == gdev.scanout.?) {
        mmio.say("kms: atomicCheck — already the scanout\n");
        return false;
    }
    if (buf.width != gdev.mode.?.hVisible or buf.height != gdev.mode.?.vVisible) {
        mmio.say("kms: atomicCheck — dims mismatch mode\n");
        return false;
    }
    return true;
}

// TEST: stage the candidate — verify GTT PTE resolves + CPU map live.
// Still zero display-register writes; proves the buffer is flippable.
pub fn atomicTest(bufHandle: u32) bool {
    if (!atomicCheck(bufHandle)) return false;
    const buf = gdev.dumbs[bufHandle].?;
    const pte = mmio.readGtt(buf.gtt_page);
    mmio.say("kms: atomicTest gtt["); mmio.sayDec(buf.gtt_page);
    mmio.say("] phys="); mmio.sayHex(pte.phys);
    mmio.say(" want="); mmio.sayHex(buf.phys); mmio.say("\n");
    if (!pte.valid or pte.phys != buf.phys) {
        stage("kms: FAIL atomicTest — GTT PTE mismatch");
        return false;
    }
    stage("kms: atomicTest passed (check+test, no hw writes)");
    return true;
}

// atomicTestQuiet — the swapchain-flavour of atomicTest: same CHECK +
// GTT PTE verification, zero stage()/say — flipSwap runs once per frame
// and per-flip LED blinks + markers would strangle the cadence.
pub fn atomicTestQuiet(bufHandle: u32) bool {
    if (!atomicCheck(bufHandle)) return false;
    const buf = gdev.dumbs[bufHandle].?;
    const pte = mmio.readGtt(buf.gtt_page);
    return pte.valid and pte.phys == buf.phys;
}

// flipSwap — the swapchain-safe commit: same check->test->commit as
// flipCommit but the PREVIOUS scanout buffer is NOT destroyed. The
// scene compositor owns a two-dumb swapchain; the retired front buffer
// becomes the next back and must stay alive. fb_base follows the newly
// scanned buffer via rebaseQuiet (no generation bump — a routine flip
// is not a surface-identity change; no serial print — flip cadence).
pub fn flipSwap(bufHandle: u32) bool {
    if (!atomicTestQuiet(bufHandle)) return false;
    const buf = gdev.dumbs[bufHandle].?;
    // QUIET by contract: this runs once per frame in the scene
    // swapchain — no stage()/say/mark here (LED blink + UDP marker per
    // flip would strangle the frame cadence). The compositor emits its
    // own stride'd scene:flip marker; failures return false and the
    // caller names them.
    pipe.pageflipSurface(buf.gtt_offset);
    const rb = pipe.surfaceOffset();
    if ((rb & ~@as(u32, 0xfff)) != (@as(u32, @intCast(buf.gtt_offset)) & ~@as(u32, 0xfff))) {
        return false;
    }
    gdev.scanout = bufHandle;
    gdev.planes[0].fb = buf;
    fb.rebaseQuiet(buf.phys, buf.pitch, buf.width, buf.height);
    return true;
}

// flipSwapFast — the FRMCNT-edge-aligned hot-path commit. Identical
// DSPASURF write + readback + bookkeeping to flipSwap but skips
// atomicTestQuiet: present.zig detects the frame boundary, then must
// land the DSPASURF write within microseconds — re-running the GTT
// PTE check between detect and commit would push the write off
// vblank and reintroduce the r9 mid-scan tearing. The buffer's
// liveness/GTT state was already proven by flipSwap on prior frames
// and by the caller's dumbGet check.
pub fn flipSwapFast(bufHandle: u32) bool {
    const buf = gdev.dumbs[bufHandle] orelse return false;
    pipe.pageflipSurface(buf.gtt_offset);
    const rb = pipe.surfaceOffset();
    if ((rb & ~@as(u32, 0xfff)) != (@as(u32, @intCast(buf.gtt_offset)) & ~@as(u32, 0xfff))) {
        return false;
    }
    gdev.scanout = bufHandle;
    gdev.planes[0].fb = buf;
    fb.rebaseQuiet(buf.phys, buf.pitch, buf.width, buf.height);
    return true;
}

// frameCount — PIPE_FRMCNT_A: increments once per scanned frame at
// the frame boundary (~vblank). NOT a vblank oracle for pacing
// decisions (r9: mid-scan commits tore) — used ONLY to edge-align
// the DSPASURF write itself and to detect flip landing.
pub fn frameCount() u32 {
    return mmio.rd(R.PIPE_FRMCNT_A);
}

// COMMIT: the atomic commit point — one DSPASURF write arms the flip the
// display engine applies at vblank. Readback verifies the request landed.
// Diagnostics flavour (kflip/kdmabuf): retires the previous scanout
// buffer — wrong for a swapchain, right for a one-shot test flip.
pub fn flipCommit(bufHandle: u32) bool {
    if (bufHandle >= gdev.dumbs.len or gdev.scanout == null) return false;
    const prev = gdev.scanout.?;
    if (!flipSwap(bufHandle)) return false;
    _ = dumbDestroy(prev); // retire old scanout frames
    return true;
}

// vblankArm — unmask the display-engine interrupt sources once (DEIMR
// active-low; 0 = all unmasked). The scene compositor's flip pacing
// polls DEIIR for vblank edges; without this the IIR stays masked and
// no events ever latch.
pub fn vblankArm() void {
    pipe.vblankEnable();
}

// vblankDrain — one quiet DEIIR read+clear. Returns raw IIR; nonzero
// means at least one vblank (or other DE event) latched since the last
// drain. No markers, no waits — the compositor polls this per tick.
pub fn vblankDrain() u32 {
    return pipe.vblankPoll();
}

// surfaceOffset — readback of the plane's programmed DSPASURF (GGTT
// byte offset, low 12 bits ignored by HW). The kstat diagnostic uses
// it to prove which buffer the display engine is pointed at.
pub fn surfaceOffset() u32 {
    return pipe.surfaceOffset();
}

// vblankRegs — the candidate vblank registers as values (for
// present.stat's sayU dual-write; mmio.say was serial-only and never
// reached the UDP wire). Order: DEISR DEIIR SDEISR SDEIIR IIR28
// GTIIR FRMCNT PSTAT24 PIPEASTAT_A(0x70024) LGC_IMR LGC_ISR
// LGC_IIR(0x20840, the Ironlake per-pipe interrupt identity reg).
// Zeros when i915 down.
pub fn vblankRegs() [11]u32 {
    if (!device().up) return @splat(0);
    return .{
        mmio.rd(R.DEISR), mmio.rd(R.DEIIR),
        mmio.rd(R.SDEISR), mmio.rd(R.SDEIIR),
        mmio.rd(R.IIR), mmio.rd(R.GTIIR),
        mmio.rd(R.PIPE_FRMCNT_A), mmio.rd(R.PIPEASTAT_A),
        mmio.rd(R.LGC_IMR), mmio.rd(R.LGC_ISR), mmio.rd(R.LGC_IIR),
    };
}

// vblankDebug — dump every candidate vblank register so T590's kstat
// names which oracle actually latches on Ironlake: engine IIRs
// (DE/SDE), the per-pipe IIR, raw ISR statuses, and PIPE_FRMCNT.
pub fn vblankDebug() void {
    if (!device().up) {
        mmio.say("kms:vb i915 down — no regs\n");
        return;
    }
    mmio.say("kms:vb DEISR="); mmio.sayHex(mmio.rd(R.DEISR));
    mmio.say(" DEIIR="); mmio.sayHex(mmio.rd(R.DEIIR));
    mmio.say(" SDEISR="); mmio.sayHex(mmio.rd(R.SDEISR));
    mmio.say(" SDEIIR="); mmio.sayHex(mmio.rd(R.SDEIIR));
    mmio.say(" IIR28="); mmio.sayHex(mmio.rd(R.IIR));
    mmio.say(" FRMCNT="); mmio.sayHex(mmio.rd(R.PIPE_FRMCNT_A));
    // Per-pipe vblank candidates (literal offsets — regs.zig lacks
    // PIPEASTAT): 0x70024 = PIPEASTAT_A (ILK: bit1=vblank, bit0=MPU),
    // 0x44018 = GTIIR (GT-engine IIR — third interrupt engine).
    mmio.say(" PSTAT24="); mmio.sayHex(mmio.rd(R.PIPEASTAT_A));
    mmio.say(" GTIIR="); mmio.sayHex(mmio.rd(R.GTIIR));
    // Ironlake legacy bank — the gen<=5 per-pipe interrupt space the
    // DE*/SDE* regs don't cover on Arrandale.
    mmio.say(" LGCIMR="); mmio.sayHex(mmio.rd(R.LGC_IMR));
    mmio.say(" LGCISR="); mmio.sayHex(mmio.rd(R.LGC_ISR));
    mmio.say(" LGCIIR="); mmio.sayHex(mmio.rd(R.LGC_IIR));
    mmio.say("\n");
}

// vw — dual-write serial + UDP (mmio.say alone never reached the wire;
// the first vbirq run proved it — T590 saw only the shell echoes).
fn vw(comptime fmt: []const u8, args: anytype) void {
    var b: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&b, fmt, args) catch return;
    b[s.len] = 0;
    mmio.say(@as([*:0]const u8, @ptrCast(&b)));
    net.mirror(s);
}

// vbirqProbe — stage-1 of the real vblank IRQ: arm the gen8+ chain
// (the path pipe.zig's ILK misdiagnosis never wrote) and count IIR
// edges. GEN8_MASTER_IRQ is deliberately NOT touched — that gates the
// CPU-facing IRQ line, so this probe cannot storm the IDT; it only
// proves vblank EVENTS latch at ~frame rate. Stage 2 routes the IRQ.
pub fn vbirqProbe() void {
    if (!device().up) {
        vw("vbirq: i915 down\n", .{});
        return;
    }
    vw("vbirq: before PSTAT={x} PISR={x} PIMR={x} PIIR={x} PIER={x} DEIER={x} DEIMR={x} DEIIR={x} FRMCNT={x}\n", .{
        mmio.rd(R.PIPEASTAT_A), mmio.rd(R.DE_PIPE_ISR_A),
        mmio.rd(R.DE_PIPE_IMR_A), mmio.rd(R.DE_PIPE_IIR_A),
        mmio.rd(R.DE_PIPE_IER_A), mmio.rd(R.DEIER),
        mmio.rd(R.DEIMR), mmio.rd(R.DEIIR), mmio.rd(R.PIPE_FRMCNT_A),
    });
    // enable chain (i915 gen8+ display_irq path):
    // 1. PIPESTAT pipestat-enable: status_mask=PIPE_VBLANK_INTERRUPT_
    //    STATUS(bit1), enable = status<<16 -> RMW |0x00020002
    mmio.wr(R.PIPEASTAT_A, mmio.rd(R.PIPEASTAT_A) | 0x0002_0002);
    // 2. per-pipe IMR: bit0 = GEN8_PIPE_VBLANK, IMR bit=1 masks -> clear
    mmio.wr(R.DE_PIPE_IMR_A, mmio.rd(R.DE_PIPE_IMR_A) & ~@as(u32, 1));
    // 3. DEIER master: DE_MASTER_IRQ_CONTROL = bit31
    mmio.wr(R.DEIER, mmio.rd(R.DEIER) | 0x8000_0000);
    // 4. DEIMR top-level: DE_PIPE_VBLANK(pipeA) = bit7, active-low
    mmio.wr(R.DEIMR, mmio.rd(R.DEIMR) & ~@as(u32, 0x80));
    vw("vbirq: armed — polling IIR edges\n", .{});
    const f0 = mmio.rd(R.PIPE_FRMCNT_A);
    var edges: u32 = 0;
    var de_edges: u32 = 0;
    var spins: u32 = 4_000_000;
    while (spins > 0) : (spins -= 1) {
        const iir = mmio.rd(R.DE_PIPE_IIR_A);
        if (iir != 0) {
            edges += 1;
            mmio.wr(R.DE_PIPE_IIR_A, iir); // W1C
        }
        const diir = mmio.rd(R.DEIIR);
        if ((diir & 0x80) != 0) {
            de_edges += 1;
            mmio.wr(R.DEIIR, diir & 0x80);
        }
    }
    const f1 = mmio.rd(R.PIPE_FRMCNT_A);
    vw("vbirq: pipeIIR edges={d} DEIIR edges={d} FRMCNT delta={d}\n", .{
        edges, de_edges, f1 -% f0,
    });
    vw("vbirq: after PISR={x} PIMR={x} PIIR={x} DEIER={x} DEIMR={x} DEIIR={x}\n", .{
        mmio.rd(R.DE_PIPE_ISR_A), mmio.rd(R.DE_PIPE_IMR_A),
        mmio.rd(R.DE_PIPE_IIR_A), mmio.rd(R.DEIER),
        mmio.rd(R.DEIMR), mmio.rd(R.DEIIR),
    });
}

// vbirqStage2 — the CPU-routing recon: stage-1 proved GEN8_DE_PIPE_IIR_A
// edges 1:1 with FRMCNT. Now enable the per-pipe IER output bit and
// dump the CPU-side facts: 0x44028 (GEN8_MASTER_IRQ candidate — the
// gen8 master that gates the i915 IRQ line to the CPU) and the PCI
// irq_line/irq_pin the firmware routed. Master IRQ NOT written yet —
// asserting it before the GSI/IDT route exists would storm vectors.
pub fn vbirqStage2() void {
    if (!device().up) {
        vw("vbirq2: i915 down\n", .{});
        return;
    }
    vw("vbirq2: before PIER={x} MIRQ28={x} irq_line={d} irq_pin={d}\n", .{
        mmio.rd(R.DE_PIPE_IER_A), mmio.rd(R.IIR),
        gdev.pdev.irq_line, gdev.pdev.irq_pin,
    });
    // per-pipe IER: GEN8_PIPE_VBLANK = bit0, IER bit=1 enables output
    mmio.wr(R.DE_PIPE_IER_A, mmio.rd(R.DE_PIPE_IER_A) | 0x0000_0001);
    // keep the stage-1 chain armed (idempotent) so events keep latching
    mmio.wr(R.PIPEASTAT_A, mmio.rd(R.PIPEASTAT_A) | 0x0002_0002);
    mmio.wr(R.DE_PIPE_IMR_A, mmio.rd(R.DE_PIPE_IMR_A) & ~@as(u32, 1));
    mmio.wr(R.DEIER, mmio.rd(R.DEIER) | 0x8000_0000);
    mmio.wr(R.DEIMR, mmio.rd(R.DEIMR) & ~@as(u32, 0x80));
    vw("vbirq2: PIER after={x} MIRQ28={x}\n", .{
        mmio.rd(R.DE_PIPE_IER_A), mmio.rd(R.IIR),
    });
    // edge sanity — same self-clearing count, short window
    var edges: u32 = 0;
    var spins: u32 = 1_000_000;
    while (spins > 0) : (spins -= 1) {
        const iir = mmio.rd(R.DE_PIPE_IIR_A);
        if (iir != 0) {
            edges += 1;
            mmio.wr(R.DE_PIPE_IIR_A, iir);
        }
    }
    vw("vbirq2: pipeIIR edges={d} (IER armed)\n", .{edges});
}

// ---- gen8+ vblank IRQ — the real CPU path --------------------------------
// Stage-3: vbirq proved generation (pipeIIR edges == FRMCNT 1:1), vbirq2
// proved the per-pipe IER write sticks. The missing gate was the master:
// on gen8+ (skl/kbl, DISPLAY_VER>=8) the CPU-facing interrupt control is
// GEN8_MASTER_IRQ at 0x44200 — NOT 0x44028 (that is GEN6_PMIIR, the GT
// power-management IIR, which is why MIRQ28 always read 0) and NOT
// DEIER/DEIMR/DEIIR (0x4400c/04/08 — the ILK-path DE bank; writes don't
// stick on gen9.2, confirmed on T590). Only bit31 of 0x44200 is writable
// (GEN8_MASTER_IRQ_CONTROL, the IER bit); bits 0-30 are read-only
// pending-source indications — GEN8_DE_PIPE_A_IRQ=bit16, _B=17, _C=18,
// DE_PORT=20, DE_MISC=22, DE_PCH=23, GT engines=0-6. Linux:
// i915_irq.c gen8_master_intr_enable writes exactly
// GEN8_MASTER_IRQ_CONTROL; gvt/interrupt.c confirms only bit31 is
// IER-writable. Full chain now: PIPESTAT pipestat-enable ->
// GEN8_DE_PIPE_IMR unmask -> GEN8_DE_PIPE_IER enable -> pipe IIR pending
// -> GEN8_MASTER_IRQ bit16 indication -> bit31 gates the PCI intline.

const GEN8_MASTER_IRQ: u32 = 0x044200;
const GEN8_MASTER_IRQ_CONTROL: u32 = 0x8000_0000;
const DE_PIPE_IIR_BASE: u32 = 0x044408; // +0x10 per pipe (A=0,B=1,C=2)
const DE_PORT_IIR: u32 = 0x044448;
const DE_MISC_IIR: u32 = 0x044468;
const GEN8_GT_IIR_BASE: u32 = 0x044308; // +0x10 per group (0..3)

extern fn koru_irq_unmask(irq: u8) void;

// IRQ-side state — written only inside i915_vblank_irq (BSP context,
// IF=0, bkl held by the dispatcher), read by vbirq3's report window.
// No allocation, no say/net — MMIO + counters only.
var vb_irq_hits: u64 = 0; // vec deliveries on the i915 line
var vb_irq_events: u64 = 0; // deliveries carrying pipe-A IIR bits
var vb_irq_last_iir: u32 = 0;
var vb_irq_last_master: u32 = 0;
var vb_irq_last_deiir: u32 = 0;

// i915_vb_irq_line — the IRQ line user.zig's dispatch claims
// (f.vec == 0x20 + line). 0xFF = inert; vbirq3 publishes it only after
// the whole chain is armed, so stray vec-0x2B deliveries before then
// still hit the unclaimed-line path.
pub export var i915_vb_irq_line: u8 = 0xFF;

// i915_vblank_irq — the IDT thunk target (extern'd by user.zig). Drains
// every gen8 interrupt-identity register the master can name so a
// non-vblank source can't hold the level line asserted after EOI:
// pipe IIRs A/B/C, DE port/misc IIRs, the legacy DEIIR, and — only when
// the master names a GT source (bits0-6) — the four GT engine-group
// IIRs. W1C = write back the read value. IRQ-safe by construction.
pub export fn i915_vblank_irq() callconv(.c) void {
    const master = mmio.rd(GEN8_MASTER_IRQ);
    var iir_a: u32 = 0;
    var p: usize = 0;
    while (p < 3) : (p += 1) {
        const off = DE_PIPE_IIR_BASE + @as(u32, @intCast(p)) * 0x10;
        const iir = mmio.rd(off);
        if (iir != 0) {
            mmio.wr(off, iir);
            if (p == 0) iir_a = iir;
        }
    }
    const dport = mmio.rd(DE_PORT_IIR);
    if (dport != 0) mmio.wr(DE_PORT_IIR, dport);
    const dmisc = mmio.rd(DE_MISC_IIR);
    if (dmisc != 0) mmio.wr(DE_MISC_IIR, dmisc);
    const deiir = mmio.rd(R.DEIIR);
    if (deiir != 0) mmio.wr(R.DEIIR, deiir);
    if ((master & 0x7F) != 0) {
        var g: usize = 0;
        while (g < 4) : (g += 1) {
            const off = GEN8_GT_IIR_BASE + @as(u32, @intCast(g)) * 0x10;
            const giir = mmio.rd(off);
            if (giir != 0) mmio.wr(off, giir);
        }
    }
    vb_irq_hits += 1;
    if (iir_a != 0) vb_irq_events += 1;
    vb_irq_last_iir = iir_a;
    vb_irq_last_master = master;
    vb_irq_last_deiir = deiir;
    // GEN8_MASTER_IRQ pending bits are W1C — Linux acks them by writing
    // the read value back. Without this the indications stay set after
    // the sources drain and a live door re-fires forever (the vbirq7
    // hang shape). bit31 rides along set, so the IER survives.
    mmio.wr(GEN8_MASTER_IRQ, master);
}

// vblankIrqCount — IRQ-driven vblank deliveries; the flipTick oracle
// the next step wires in (0 until vbirq3 arms the chain).
pub fn vblankIrqCount() u64 {
    return vb_irq_hits;
}

// vbirq3 — stage-3: the real vblank IRQ end to end. Arms the proven
// gen8 chain, publishes the PCI IRQ line to the dispatch, unmasks it at
// the IOAPIC (T590: irq 11 -> vec 0x2B, LAPIC-delivered, eoiVec picks
// the LAPIC EOI automatically), THEN writes GEN8_MASTER_IRQ_CONTROL —
// handler+gate live before the device-side gate opens. ~2s count
// window: irq_hits should track the FRMCNT delta ~1:1 at 60Hz.
pub fn vbirq3() void {
    if (!device().up) {
        vw("vbirq3: i915 down\n", .{});
        return;
    }
    const irq = gdev.pdev.irq_line;
    vw("vbirq3: irq_line={d} irq_pin={d} -> vec {x}\n", .{
        irq, gdev.pdev.irq_pin, @as(u64, irq) + 0x20,
    });
    if (irq == 0 or irq == 0xFF) {
        vw("vbirq3: no IRQ line — refusing to arm\n", .{});
        return;
    }
    // gen8 chain — the vbirq/vbirq2-proven writes. DEIER/DEIMR/DEIIR are
    // the ILK path and don't stick on gen9.2; deliberately skipped.
    mmio.wr(R.PIPEASTAT_A, mmio.rd(R.PIPEASTAT_A) | 0x0002_0002);
    mmio.wr(R.DE_PIPE_IMR_A, mmio.rd(R.DE_PIPE_IMR_A) & ~@as(u32, 1));
    mmio.wr(R.DE_PIPE_IER_A, mmio.rd(R.DE_PIPE_IER_A) | 0x0000_0001);
    // drain a stale latched event so the window counts fresh edges only
    const stale = mmio.rd(R.DE_PIPE_IIR_A);
    if (stale != 0) mmio.wr(R.DE_PIPE_IIR_A, stale);
    // CPU door first: handler claim published, line unmasked, then the
    // device-side master opens. A level line stays asserted until the
    // IIR clears, so even a missed first edge re-delivers.
    i915_vb_irq_line = irq;
    koru_irq_unmask(irq);
    mmio.wr(GEN8_MASTER_IRQ, GEN8_MASTER_IRQ_CONTROL);
    vw("vbirq3: armed MIRQ44200={x} (bit31 ctl | pending srcs)\n", .{
        mmio.rd(GEN8_MASTER_IRQ),
    });
    const f0 = mmio.rd(R.PIPE_FRMCNT_A);
    const h0 = vb_irq_hits;
    const e0 = vb_irq_events;
    mmio.sleepMs(2000);
    vw("vbirq3: irq_hits={d} vb_events={d} FRMCNT delta={d} last_iir={x} last_master={x} deiir={x}\n", .{
        vb_irq_hits - h0, vb_irq_events - e0,
        mmio.rd(R.PIPE_FRMCNT_A) -% f0,
        vb_irq_last_iir, vb_irq_last_master, vb_irq_last_deiir,
    });
}

// vbirq4 — the delivery-vs-generation split. vbirq3 armed the whole
// chain and got irq_hits=0 with FRMCNT still ticking: either an enable
// is still missing between the pipe IER and GEN8_MASTER_IRQ (the
// master never sees a pending source) or the INTx->IO-APIC->LAPIC leg
// is broken. Phase A answers the first: the chain and bit31 are armed
// while the IO-APIC RTE stays masked — INTx may assert at the pin but
// nothing can deliver — then GEN8_MASTER_IRQ's read-only pending
// indications are sampled. bit16 (DE_PIPE_A) set while pipe IIR is
// pending proves generation reaches the master. Phase B dumps the RTE
// (mask/trigger/polarity/vector/dest), sharers on the line, and the
// PCI INTx-disable bit, then unmasks and counts hits: hits=0 after a
// proven-pending master is a pure delivery failure.
pub fn vbirq4() void {
    if (!device().up) {
        vw("vbirq4: i915 down\n", .{});
        return;
    }
    const irq = gdev.pdev.irq_line;
    if (ioapic.rteRead(irq)) |rte| {
        vw("vbirq4: irq={d} gsi={d} rte_lo={x} rte_hi={x} vec={x} mask={d} lvl={d} low={d} dmode={x} dst={x}\n", .{
            irq, rte.gsi, rte.lo, rte.hi, rte.lo & 0xFF,
            (rte.lo >> 16) & 1, (rte.lo >> 15) & 1, (rte.lo >> 13) & 1,
            (rte.lo >> 8) & 7, (rte.hi >> 24) & 0xFF,
        });
    } else {
        vw("vbirq4: irq={d} — no IO-APIC route\n", .{irq});
    }
    var sharers: u32 = 0;
    for (pci.devices[0..pci.count]) |d| {
        if (d.irq_line == irq and d.irq_pin != 0) {
            sharers += 1;
            vw("vbirq4: sharer {x}:{x}.{x} pin={d}\n", .{
                d.bus, d.slot, d.func, d.irq_pin,
            });
        }
    }
    const cmd = pci.command(&gdev.pdev);
    vw("vbirq4: sharers={d} cmd={x} intx_dis={d} msi_cap={x} msix_cap={x}\n", .{
        sharers, cmd, (cmd >> 10) & 1,
        @intFromBool(pci.capFind(&gdev.pdev, 0x05) != 0),
        @intFromBool(pci.capFind(&gdev.pdev, 0x11) != 0),
    });
    // Phase A — pending-at-master with the CPU door still shut.
    mmio.wr(R.PIPEASTAT_A, mmio.rd(R.PIPEASTAT_A) | 0x0002_0002);
    mmio.wr(R.DE_PIPE_IMR_A, mmio.rd(R.DE_PIPE_IMR_A) & ~@as(u32, 1));
    mmio.wr(R.DE_PIPE_IER_A, mmio.rd(R.DE_PIPE_IER_A) | 0x0000_0001);
    const stale = mmio.rd(R.DE_PIPE_IIR_A);
    if (stale != 0) mmio.wr(R.DE_PIPE_IIR_A, stale);
    const f0 = mmio.rd(R.PIPE_FRMCNT_A);
    mmio.wr(GEN8_MASTER_IRQ, GEN8_MASTER_IRQ_CONTROL);
    mmio.sleepMs(100);
    const mast0 = mmio.rd(GEN8_MASTER_IRQ);
    const iir0 = mmio.rd(R.DE_PIPE_IIR_A);
    const dport = mmio.rd(DE_PORT_IIR);
    const dmisc = mmio.rd(DE_MISC_IIR);
    const f1 = mmio.rd(R.PIPE_FRMCNT_A);
    // W1C the pipe IIR and re-read ~instantly: bit16 dropping with the
    // source cleared is the causality check (next vblank is ~16ms out).
    if (iir0 != 0) mmio.wr(R.DE_PIPE_IIR_A, iir0);
    const mast1 = mmio.rd(GEN8_MASTER_IRQ);
    vw("vbirq4: master0={x} master1={x} pipeIIR={x} dport={x} dmisc={x} FRMCNT delta={d}\n", .{
        mast0, mast1, iir0, dport, dmisc, f1 -% f0,
    });
    // Phase B — delivery. Claim the line, unmask the RTE, count.
    if (irq != 0 and irq != 0xFF) {
        i915_vb_irq_line = irq;
        koru_irq_unmask(irq);
        if (ioapic.rteRead(irq)) |rte| {
            vw("vbirq4: post-unmask rte_lo={x} mask={d}\n", .{
                rte.lo, (rte.lo >> 16) & 1,
            });
        }
        const h0 = vb_irq_hits;
        const e0 = vb_irq_events;
        mmio.sleepMs(2000);
        vw("vbirq4: irq_hits={d} vb_events={d} FRMCNT delta={d} last_master={x}\n", .{
            vb_irq_hits - h0, vb_irq_events - e0,
            mmio.rd(R.PIPE_FRMCNT_A) -% f1,
            vb_irq_last_master,
        });
    } else {
        vw("vbirq4: no IRQ line — phase B skipped\n", .{});
    }
}

// vbirqLatest — the plain 'vbirq' command's target. The T590 keyboard
// has a dead '5' key, so digit-suffixed probe names are untypeable on
// the box that runs them; the unsuffixed command always runs the
// NEWEST stage. Future stages: add the fn, point this at it.
pub fn vbirqLatest() void {
    vbirq9();
}

extern var msi_any_seen: u64;
extern var irq_ticks: u64;
extern fn koru_lapic_probe() u64;
extern fn koru_lapic_armed() u64;
extern var lapicMapResult: u64;

// vdiag — kms-independent state dump. The wire only dies AFTER kms,
// so boot-time APIC/pmm truth must be readable at the bare shell:
// pmm managed/live (is the allocator really dead on UEFI?), lapic
// probe (armed? real id/svr?), ioapic probe (found? live?), and the
// any-MSI counter. No i915 dependency — run before kms.
pub fn vdiag() void {
    const ps = pmm.state();
    const lp = koru_lapic_probe();
    vw("vdiag: pmm managed={d} live={d} limit={d} maxf={d}\n", .{
        ps.managed, ps.live, ps.limit, ps.maxframes,
    });
    vw("vdiag: lapic probe={x} (idreg<<32|svr; 0=unarmed)\n", .{lp});
    vw("vdiag: ioapic ok={} id={x} ver={x} pins={d} live={} gsiFor11={}\n", .{
        @intFromBool(ioapic.probeOk), ioapic.probeId, ioapic.probeVer,
        ioapic.probePins, @intFromBool(ioapic.isLive()),
        ioapic.gsiFor(11) orelse 0xFFFF,
    });
    vw("vdiag: msi_any={d} irq_ticks={d}\n", .{ msi_any_seen, irq_ticks });
    // Page-table truth — splits 'map refused' from 'mapped, device
    // silent'. pdpt[3] must be nonzero and each 2MiB PDE must carry
    // present|rw|PCD|PS (0x93-ish) for the window to reach silicon.
    const lapIdx: u32 = @intCast((0xFEE00000 >> 21) & 0x1FF);
    const ioaIdx: u32 = @intCast((0xFEC00000 >> 21) & 0x1FF);
    vw("vdiag: GB3 pdpt={x} lapPde={x} ioaPde={x} lapicArmed={} mapCalls={} pdInst={} lapMap={}\n", .{
        hostmmio.pdptEntry(3), hostmmio.pdEntry(3, lapIdx), hostmmio.pdEntry(3, ioaIdx),
        koru_lapic_armed(), hostmmio.mapCalls, hostmmio.pdInstalled, lapicMapResult,
    });
}

// vbirq9 — the mmio.map fix. vbirq8 measured lapic probe=0: the LAPIC
// (and IO-APIC) windows sit in GB3, and mmio.map minted their page
// directories via pmm.alloc — which returns null forever when pmm.init
// finds no mb2 mmap tag. T590 boots UEFI-GRUB where that tag apparently
// never arrives (QEMU's BIOS path has it: usable=1023MiB managed=262144).
// Page directories are permanent kernel metadata — mmio.zig now mints
// them from a static pool, so GB3 maps at boot regardless of pmm.
// This probe dumps pmm.state() to confirm managed=0 on the wire, then
// runs the full MSI recon: lapic probe (should be nonzero now), real
// apic dest, MSI readback, msi_any_seen, 2s count.
pub fn vbirq9() void {
    if (!device().up) {
        vw("vbirq9: i915 down\n", .{});
        return;
    }
    const ps = pmm.state();
    const lp = koru_lapic_probe();
    const lapid: u32 = @intCast(lp >> 32);
    const dest: u32 = if (lp == 0) 0 else (lapid >> 24) & 0xFF;
    vw("vbirq9: pmm managed={d} live={d} | lapic={x} apicid={d} | ioapic ok={} id={x} ver={x} pins={d} live={} | msi_any={d}\n", .{
        ps.managed, ps.live, lp, dest,
        @intFromBool(ioapic.probeOk), ioapic.probeId, ioapic.probeVer,
        ioapic.probePins, @intFromBool(ioapic.isLive()), msi_any_seen,
    });
    const cap = pci.capFind(&gdev.pdev, 0x05);
    if (cap == 0) {
        vw("vbirq9: no MSI cap\n", .{});
        return;
    }
    const d = &gdev.pdev;
    const ctrl = pci.read16(d.bus, d.slot, d.func, cap + 2);
    const is64 = (ctrl & 0x80) != 0;
    const dataOff: u8 = if (is64) 0x0C else 0x08;
    const maskOff: u8 = if (is64) 0x10 else 0x0A;
    const maddr: u32 = 0xFEE00000 | (dest << 12);
    vw("vbirq9: cap={x} ctrl={x} is64={} pvm={} dest={x} maddr={x}\n", .{
        cap, ctrl, @intFromBool(is64), @intFromBool(ctrl & 0x100 != 0),
        dest, maddr,
    });
    pci.write32(d.bus, d.slot, d.func, cap + 4, maddr);
    if (is64) pci.write32(d.bus, d.slot, d.func, cap + 8, 0);
    pci.write16(d.bus, d.slot, d.func, cap + dataOff, I915_MSI_VEC);
    if (ctrl & 0x100 != 0) pci.write16(d.bus, d.slot, d.func, cap + maskOff, 0);
    i915_msi_vec = I915_MSI_VEC;
    pci.write16(d.bus, d.slot, d.func, cap + 2, ctrl | 0x0001);
    pci.setCommand(d, pci.command(d) | 0x0400);
    vw("vbirq9: armed ctrl={x} addr={x} data={x}\n", .{
        pci.read16(d.bus, d.slot, d.func, cap + 2),
        pci.read32(d.bus, d.slot, d.func, cap + 4),
        pci.read16(d.bus, d.slot, d.func, cap + dataOff),
    });
    mmio.wr(R.PIPEASTAT_A, mmio.rd(R.PIPEASTAT_A) | 0x0002_0002);
    mmio.wr(R.DE_PIPE_IMR_A, mmio.rd(R.DE_PIPE_IMR_A) & ~@as(u32, 1));
    mmio.wr(R.DE_PIPE_IER_A, mmio.rd(R.DE_PIPE_IER_A) | 0x0000_0001);
    const stale = mmio.rd(R.DE_PIPE_IIR_A);
    if (stale != 0) mmio.wr(R.DE_PIPE_IIR_A, stale);
    mmio.wr(GEN8_MASTER_IRQ, GEN8_MASTER_IRQ_CONTROL);
    vw("vbirq9: master={x} counting\n", .{ mmio.rd(GEN8_MASTER_IRQ) });
    const f0 = mmio.rd(R.PIPE_FRMCNT_A);
    const h0 = vb_irq_hits;
    const e0 = vb_irq_events;
    const a0 = msi_any_seen;
    mmio.sleepMs(2000);
    vw("vbirq9: irq_hits={d} vb_events={d} msi_any={d} FRMCNT delta={d} last_master={x}\n", .{
        vb_irq_hits - h0, vb_irq_events - e0, msi_any_seen - a0,
        mmio.rd(R.PIPE_FRMCNT_A) -% f0, vb_irq_last_master,
    });
}

// vbirq8 — vbirq7's hang fix + same recon. vbirq7's first act was a
// raw 0xFEE00020/0xFEE000F0 deref: if the LAPIC window never mapped on
// T590 that is an immediate page fault -> frozen screen, zero output —
// exactly what the wire showed. koru_lapic_probe answers the same
// question through user.zig's lapicArmed guard (0 = unarmed, no
// deref). The handler also gained the GEN8_MASTER_IRQ W1C ack — the
// pending indications are write-1-to-clear and were sticking set,
// which is the storm shape if MSI ever did deliver. msi_any_seen
// still splits 'wrong vector' from 'no arrival'.
pub fn vbirq8() void {
    if (!device().up) {
        vw("vbirq8: i915 down\n", .{});
        return;
    }
    const lp = koru_lapic_probe();
    const lapid: u32 = @intCast(lp >> 32);
    const dest: u32 = if (lp == 0) 0 else (lapid >> 24) & 0xFF;
    vw("vbirq8: lapic probe={x} apicid={d} msi_any={d}\n", .{
        lp, dest, msi_any_seen,
    });
    const cap = pci.capFind(&gdev.pdev, 0x05);
    if (cap == 0) {
        vw("vbirq8: no MSI cap\n", .{});
        return;
    }
    const d = &gdev.pdev;
    const ctrl = pci.read16(d.bus, d.slot, d.func, cap + 2);
    const is64 = (ctrl & 0x80) != 0;
    const dataOff: u8 = if (is64) 0x0C else 0x08;
    const maskOff: u8 = if (is64) 0x10 else 0x0A;
    const maddr: u32 = 0xFEE00000 | (dest << 12);
    vw("vbirq8: cap={x} ctrl={x} is64={} pvm={} dest={x} maddr={x}\n", .{
        cap, ctrl, @intFromBool(is64), @intFromBool(ctrl & 0x100 != 0),
        dest, maddr,
    });
    pci.write32(d.bus, d.slot, d.func, cap + 4, maddr);
    if (is64) pci.write32(d.bus, d.slot, d.func, cap + 8, 0);
    pci.write16(d.bus, d.slot, d.func, cap + dataOff, I915_MSI_VEC);
    if (ctrl & 0x100 != 0) pci.write16(d.bus, d.slot, d.func, cap + maskOff, 0);
    i915_msi_vec = I915_MSI_VEC;
    pci.write16(d.bus, d.slot, d.func, cap + 2, ctrl | 0x0001);
    pci.setCommand(d, pci.command(d) | 0x0400);
    vw("vbirq8: armed ctrl={x} addr={x} data={x}\n", .{
        pci.read16(d.bus, d.slot, d.func, cap + 2),
        pci.read32(d.bus, d.slot, d.func, cap + 4),
        pci.read16(d.bus, d.slot, d.func, cap + dataOff),
    });
    mmio.wr(R.PIPEASTAT_A, mmio.rd(R.PIPEASTAT_A) | 0x0002_0002);
    mmio.wr(R.DE_PIPE_IMR_A, mmio.rd(R.DE_PIPE_IMR_A) & ~@as(u32, 1));
    mmio.wr(R.DE_PIPE_IER_A, mmio.rd(R.DE_PIPE_IER_A) | 0x0000_0001);
    const stale = mmio.rd(R.DE_PIPE_IIR_A);
    if (stale != 0) mmio.wr(R.DE_PIPE_IIR_A, stale);
    mmio.wr(GEN8_MASTER_IRQ, GEN8_MASTER_IRQ_CONTROL);
    vw("vbirq8: master={x} counting\n", .{ mmio.rd(GEN8_MASTER_IRQ) });
    const f0 = mmio.rd(R.PIPE_FRMCNT_A);
    const h0 = vb_irq_hits;
    const e0 = vb_irq_events;
    const a0 = msi_any_seen;
    mmio.sleepMs(2000);
    vw("vbirq8: irq_hits={d} vb_events={d} msi_any={d} FRMCNT delta={d} last_master={x}\n", .{
        vb_irq_hits - h0, vb_irq_events - e0, msi_any_seen - a0,
        mmio.rd(R.PIPE_FRMCNT_A) -% f0, vb_irq_last_master,
    });
}

// vbirq7 — MSI arrived nowhere: vbirq6 armed the cap cleanly
// (ctrl 0->1, INTx disabled) yet irq_hits stayed 0. Three things were
// never verified: the LAPIC's own state (id/svr — is the receiving
// door even armed, and is dest=0 the right target), whether the MSI
// register writes actually stuck (never read back), and whether ANY
// vec>=0x30 delivery reaches the CPU at all (stray reports are
// serial-only — msi_any_seen is the wire-visible count). This probe
// dumps all three, reprograms the message with the REAL bsp apic id
// in the dest field, and recounts.
pub fn vbirq7() void {
    if (!device().up) {
        vw("vbirq7: i915 down\n", .{});
        return;
    }
    const lapid = @as(*volatile u32, @ptrFromInt(@as(usize, 0xFEE00020))).*;
    const svr = @as(*volatile u32, @ptrFromInt(@as(usize, 0xFEE000F0))).*;
    const dest: u32 = (lapid >> 24) & 0xFF;
    vw("vbirq7: lapic idreg={x} apicid={d} svr={x} msi_any={d}\n", .{
        lapid, dest, svr, msi_any_seen,
    });
    const cap = pci.capFind(&gdev.pdev, 0x05);
    if (cap == 0) {
        vw("vbirq7: no MSI cap\n", .{});
        return;
    }
    const d = &gdev.pdev;
    const ctrl = pci.read16(d.bus, d.slot, d.func, cap + 2);
    const is64 = (ctrl & 0x80) != 0;
    const dataOff: u8 = if (is64) 0x0C else 0x08;
    const maskOff: u8 = if (is64) 0x10 else 0x0A;
    const maddr: u32 = 0xFEE00000 | (dest << 12);
    vw("vbirq7: cap={x} ctrl={x} is64={} pvm={} dest={x} maddr={x}\n", .{
        cap, ctrl, @intFromBool(is64), @intFromBool(ctrl & 0x100 != 0),
        dest, maddr,
    });
    pci.write32(d.bus, d.slot, d.func, cap + 4, maddr);
    if (is64) pci.write32(d.bus, d.slot, d.func, cap + 8, 0);
    pci.write16(d.bus, d.slot, d.func, cap + dataOff, I915_MSI_VEC);
    if (ctrl & 0x100 != 0) pci.write16(d.bus, d.slot, d.func, cap + maskOff, 0);
    i915_msi_vec = I915_MSI_VEC;
    pci.write16(d.bus, d.slot, d.func, cap + 2, ctrl | 0x0001);
    pci.setCommand(d, pci.command(d) | 0x0400);
    // readback — did the device actually keep the message?
    vw("vbirq7: armed ctrl={x} addr={x} data={x}\n", .{
        pci.read16(d.bus, d.slot, d.func, cap + 2),
        pci.read32(d.bus, d.slot, d.func, cap + 4),
        pci.read16(d.bus, d.slot, d.func, cap + dataOff),
    });
    mmio.wr(R.PIPEASTAT_A, mmio.rd(R.PIPEASTAT_A) | 0x0002_0002);
    mmio.wr(R.DE_PIPE_IMR_A, mmio.rd(R.DE_PIPE_IMR_A) & ~@as(u32, 1));
    mmio.wr(R.DE_PIPE_IER_A, mmio.rd(R.DE_PIPE_IER_A) | 0x0000_0001);
    const stale = mmio.rd(R.DE_PIPE_IIR_A);
    if (stale != 0) mmio.wr(R.DE_PIPE_IIR_A, stale);
    mmio.wr(GEN8_MASTER_IRQ, GEN8_MASTER_IRQ_CONTROL);
    vw("vbirq7: master={x} counting\n", .{ mmio.rd(GEN8_MASTER_IRQ) });
    const f0 = mmio.rd(R.PIPE_FRMCNT_A);
    const h0 = vb_irq_hits;
    const e0 = vb_irq_events;
    const a0 = msi_any_seen;
    mmio.sleepMs(2000);
    vw("vbirq7: irq_hits={d} vb_events={d} msi_any={d} FRMCNT delta={d} last_master={x}\n", .{
        vb_irq_hits - h0, vb_irq_events - e0, msi_any_seen - a0,
        mmio.rd(R.PIPE_FRMCNT_A) -% f0, vb_irq_last_master,
    });
}

// i915_msi_vec — the MSI door's IDT vector, published to user.zig's
// vec>=0x30 dispatch arm. 0xFF = unarmed; vbirq6 sets it once the MSI
// message is programmed so stray deliveries before then still report.
pub export var i915_msi_vec: u8 = 0xFF;

const I915_MSI_VEC: u8 = 0x32; // free: 0x30 gpu-msix, 0x3D/0x3E smp

// vbirq6 — the MSI door. vbirq5 measured the real wall: T590 has no
// reachable IO-APIC (the 0xFEC00000 direct probe refused too — no
// sane VER) and the 8259 is edge-only, so level-held PCI INTx has no
// legal door. But vbirq4 measured msi_cap=1: the i915 has an MSI
// capability — the device writes the LAPIC directly, bypassing both
// controllers. That is the path Linux i915 uses by default.
// Program: msg addr 0xFEE00000 (BSP, phys dest) + data=vec, honour
// 64-bit layout when the cap offers it, clear PVM mask if present,
// THEN enable MSI + INTx-disable, with the dispatch arm already live.
// irq_hits>0 closes the vblank-IRQ rung.
pub fn vbirq6() void {
    if (!device().up) {
        vw("vbirq6: i915 down\n", .{});
        return;
    }
    const cap = pci.capFind(&gdev.pdev, 0x05);
    if (cap == 0) {
        vw("vbirq6: no MSI cap\n", .{});
        return;
    }
    const d = &gdev.pdev;
    const ctrl = pci.read16(d.bus, d.slot, d.func, cap + 2);
    const is64 = (ctrl & 0x80) != 0;
    const dataOff: u8 = if (is64) 0x0C else 0x08;
    const maskOff: u8 = if (is64) 0x10 else 0x0A;
    vw("vbirq6: msi cap={x} ctrl={x} is64={} pvm={} vec={x}\n", .{
        cap, ctrl, @intFromBool(is64), @intFromBool(ctrl & 0x100 != 0),
        I915_MSI_VEC,
    });
    // program while disabled — addr, data, mask — then publish the
    // vector, enable MSI, INTx-disable the pin.
    pci.write32(d.bus, d.slot, d.func, cap + 4, 0xFEE00000);
    if (is64) pci.write32(d.bus, d.slot, d.func, cap + 8, 0);
    pci.write16(d.bus, d.slot, d.func, cap + dataOff, I915_MSI_VEC);
    if (ctrl & 0x100 != 0) pci.write16(d.bus, d.slot, d.func, cap + maskOff, 0);
    i915_msi_vec = I915_MSI_VEC;
    pci.write16(d.bus, d.slot, d.func, cap + 2, ctrl | 0x0001);
    pci.setCommand(d, pci.command(d) | 0x0400);
    vw("vbirq6: msi armed ctrl={x} cmd={x}\n", .{
        pci.read16(d.bus, d.slot, d.func, cap + 2), pci.command(d),
    });
    // proven gen8 chain + master — same writes as vbirq3/5.
    mmio.wr(R.PIPEASTAT_A, mmio.rd(R.PIPEASTAT_A) | 0x0002_0002);
    mmio.wr(R.DE_PIPE_IMR_A, mmio.rd(R.DE_PIPE_IMR_A) & ~@as(u32, 1));
    mmio.wr(R.DE_PIPE_IER_A, mmio.rd(R.DE_PIPE_IER_A) | 0x0000_0001);
    const stale = mmio.rd(R.DE_PIPE_IIR_A);
    if (stale != 0) mmio.wr(R.DE_PIPE_IIR_A, stale);
    mmio.wr(GEN8_MASTER_IRQ, GEN8_MASTER_IRQ_CONTROL);
    vw("vbirq6: counting\n", .{});
    const f0 = mmio.rd(R.PIPE_FRMCNT_A);
    const h0 = vb_irq_hits;
    const e0 = vb_irq_events;
    mmio.sleepMs(2000);
    vw("vbirq6: irq_hits={d} vb_events={d} FRMCNT delta={d} last_iir={x} last_master={x}\n", .{
        vb_irq_hits - h0, vb_irq_events - e0,
        mmio.rd(R.PIPE_FRMCNT_A) -% f0,
        vb_irq_last_iir, vb_irq_last_master,
    });
}

// vbirq5 — the route fix. vbirq4 proved generation reaches the master
// (master0=80010000, bit16 pending while pipeIIR=1) AND proved irq11
// has NO IO-APIC route: gsiFor(11)=null, so koru_irq_unmask fell back
// to the PIC door — masked shut since boot. The INTx was asserted the
// whole time with no route to carry it. This probe dumps the MADT
// facts that made route(11) refuse (ISO table, npins, gsi-base, the
// full irq->gsi table), force-routes irq11 at gsi=irq with PCI INTx
// defaults (level/low — the ISA-conformant answer; IRQ11 essentially
// never has a real override), then runs the proven arm+unmask+count.
// irq_hits>0 closes the vblank-IRQ rung.
pub fn vbirq5() void {
    if (!device().up) {
        vw("vbirq5: i915 down\n", .{});
        return;
    }
    const irq = gdev.pdev.irq_line;
    vw("vbirq5: acpi found={} tables={d} | ioapic live={} pins={d} gsi-base={d} isos={d} npci={d}\n", .{
        @intFromBool(acpi.found), acpi.ntables,
        @intFromBool(ioapic.isLive()), ioapic.pinCount(),
        acpi.ioapicGsiBase, acpi.isos, pci.count,
    });
    for (acpi.isoList[0..@min(acpi.isos, 32)]) |e| {
        vw("vbirq5: iso src={d} gsi={d} flags={x}\n", .{ e.src, e.gsi, e.flags });
    }
    for (0..16) |l| {
        const r = ioapic.lineRoute(@intCast(l));
        if (r.gsi >= 0)
            vw("vbirq5: line {d} -> gsi {d} lapic={}\n", .{
                l, r.gsi, @intFromBool(r.lapic),
            });
    }
    if (!ioapic.forceRoute(irq, irq)) {
        vw("vbirq5: forceRoute irq={d} gsi={d} refused\n", .{ irq, irq });
        return;
    }
    vw("vbirq5: irq={d} force-routed gsi={d}\n", .{ irq, irq });
    if (ioapic.rteRead(irq)) |rte| {
        vw("vbirq5: rte_lo={x} rte_hi={x} vec={x} mask={d} lvl={d} low={d} dst={x}\n", .{
            rte.lo, rte.hi, rte.lo & 0xFF, (rte.lo >> 16) & 1,
            (rte.lo >> 15) & 1, (rte.lo >> 13) & 1, (rte.hi >> 24) & 0xFF,
        });
    }
    // proven arm sequence (vbirq3): pipe chain -> drain stale -> claim
    // line -> unmask -> master control LAST.
    mmio.wr(R.PIPEASTAT_A, mmio.rd(R.PIPEASTAT_A) | 0x0002_0002);
    mmio.wr(R.DE_PIPE_IMR_A, mmio.rd(R.DE_PIPE_IMR_A) & ~@as(u32, 1));
    mmio.wr(R.DE_PIPE_IER_A, mmio.rd(R.DE_PIPE_IER_A) | 0x0000_0001);
    const stale = mmio.rd(R.DE_PIPE_IIR_A);
    if (stale != 0) mmio.wr(R.DE_PIPE_IIR_A, stale);
    i915_vb_irq_line = irq;
    ioapic.picMask(irq); // one door only — level INTx must not double-deliver
    koru_irq_unmask(irq);
    mmio.wr(GEN8_MASTER_IRQ, GEN8_MASTER_IRQ_CONTROL);
    vw("vbirq5: armed — counting\n", .{});
    const f0 = mmio.rd(R.PIPE_FRMCNT_A);
    const h0 = vb_irq_hits;
    const e0 = vb_irq_events;
    mmio.sleepMs(2000);
    vw("vbirq5: irq_hits={d} vb_events={d} FRMCNT delta={d} last_iir={x} last_master={x}\n", .{
        vb_irq_hits - h0, vb_irq_events - e0,
        mmio.rd(R.PIPE_FRMCNT_A) -% f0,
        vb_irq_last_iir, vb_irq_last_master,
    });
}

// VBLANK: enable DE interrupts, then poll IIR for `n` events (bounded).
// Returns events seen — 0 means the IIR didn't latch (still reports the
// flip committed; the scanout swap is visible regardless).
pub fn vblankWait(n: u32) u32 {
    pipe.vblankEnable();
    var seen: u32 = 0;
    var spins: u64 = 0;
    const maxSpins: u64 = 200_000_000; // ~frame-time-ish bound per event
    _ = pipe.vblankPoll(); // drain stale
    while (seen < n and spins < maxSpins * @as(u64, n)) : (spins += 1) {
        if (pipe.vblankPoll() != 0) {
            seen += 1;
            mmio.say("kms: vblank event "); mmio.sayDec(seen); mmio.say("\n");
            net.mark("kms:vblank");
        }
        asm volatile ("pause");
    }
    mmio.say("kms: vblank wait done events="); mmio.sayDec(seen); mmio.say("\n");
    stage("kms: vblank events delivered");
    return seen;
}

// runFlip: full M2 atomic pageflip — requires a live 'kms' modeset.
// Creates a second dumb buffer, fills the flip pattern, runs the
// check->test->commit sequence, then collects vblank events.
pub fn runFlip() void {
    stage("kms: ==== M2 atomic pageflip ====");
    if (!probe()) return;
    if (gdev.scanout == null) {
        stage("kms: no live scanout — run 'kms' first");
        return;
    }
    const h = dumbCreate(1920, 1080, 32) orelse return;
    const buf = gdev.dumbs[h].?;
    fillFlipPattern(&buf);
    if (!flipCommit(h)) {
        _ = dumbDestroy(h);
        return;
    }
    // two vblanks prove the flip landed and the event path streams
    _ = vblankWait(2);
    text.puts("KORU M2 atomic pageflip live\n");
    stage("kms: ==== M2 atomic complete ====");
}

// ---- M3 dmabuf: shareable producer->scanout buffer ---------------------------
// The compositor seam. A producer (draw surface / app / console) renders
// into a CPU-mapped buffer it does NOT own the display path for; it hands
// an importable token to the KMS side, which resolves it to a dumb buffer
// and pageflips it through the M2 atomic path. Producer and scanout are
// decoupled: the producer never touches an i915 register.
//
// Modelled on dma-buf: the "fd" is a token into an export table. The
// backing store is a DumbBuffer (GGTT-mapped for scanout, identity-CPU
// mapped for the producer, pmm-owned for lifetime). refs counts holders —
// producer + display — so a buffer can't be freed while scanned.

pub const MAX_DMABUFS: usize = 16;

const DmabufEnt = struct {
    token: u32 = 0,
    handle: u32 = 0, // dumb handle backing the export
    refs: u32 = 0,   // producer + importer holds
    live: bool = false,
};

var dmabufs: [MAX_DMABUFS]DmabufEnt = @splat(.{});
var dmabufNextToken: u32 = 1;

// Producer side: allocate a shareable buffer and get its import token.
// Wraps dumbCreate — the buffer is GGTT-mapped + CPU-accessible already.
pub fn dmabufCreate(w: u32, h: u32) ?u32 {
    var slot: ?usize = null;
    var si: usize = 0;
    while (si < dmabufs.len) : (si += 1) {
        if (!dmabufs[si].live) {
            slot = si;
            break;
        }
    }
    const s = slot orelse {
        mmio.say("kms: dmabufCreate refused — export table full\n");
        return null;
    };
    const handle = dumbCreate(w, h, 32) orelse return null;
    const tok = dmabufNextToken;
    dmabufNextToken += 1;
    dmabufs[s] = .{ .token = tok, .handle = handle, .refs = 1, .live = true };
    mmio.say("kms: dmabuf export token="); mmio.sayDec(tok);
    mmio.say(" handle="); mmio.sayDec(handle); mmio.say("\n");
    stage("kms: dmabuf created+exported");
    return tok;
}

// Look up the CPU-mapped backing store for a token — the producer's
// render target. Null if the token isn't a live export.
pub fn dmabufMap(token: u32) ?*const DumbBuffer {
    var i: usize = 0;
    while (i < dmabufs.len) : (i += 1) {
        if (dmabufs[i].live and dmabufs[i].token == token) {
            return dumbGet(dmabufs[i].handle);
        }
    }
    return null;
}

// Import side: the display/KMS resolves a token to a dumb handle it can
// atomic-flip. Adds a display ref so the producer can't free it mid-scan.
pub fn dmabufImport(token: u32) ?u32 {
    var i: usize = 0;
    while (i < dmabufs.len) : (i += 1) {
        if (dmabufs[i].live and dmabufs[i].token == token) {
            dmabufs[i].refs += 1;
            mmio.say("kms: dmabuf import token="); mmio.sayDec(token);
            mmio.say(" -> handle="); mmio.sayDec(dmabufs[i].handle);
            mmio.say(" refs="); mmio.sayDec(dmabufs[i].refs); mmio.say("\n");
            stage("kms: dmabuf imported by display");
            return dmabufs[i].handle;
        }
    }
    mmio.say("kms: dmabufImport refused — bad token "); mmio.sayDec(token);
    mmio.say("\n");
    return null;
}

// Lifetime: drop a holder's ref; frees the export+dumb only at zero.
pub fn dmabufUnref(token: u32) void {
    var i: usize = 0;
    while (i < dmabufs.len) : (i += 1) {
        if (dmabufs[i].live and dmabufs[i].token == token) {
            if (dmabufs[i].refs > 0) dmabufs[i].refs -= 1;
            if (dmabufs[i].refs == 0) {
                _ = dumbDestroy(dmabufs[i].handle);
                dmabufs[i].live = false;
                mmio.say("kms: dmabuf token="); mmio.sayDec(token);
                mmio.say(" released (refs=0)\n");
            }
            return;
        }
    }
}

// ---- producer render ---------------------------------------------------------
// A stand-in for a real producer (draw surface / app). Renders a window-
// like surface into the dmabuf's CPU map: dark backdrop, a title bar, a
// gradient client area, an accent block. Deliberately unlike the M1/M2
// test patterns — proof the scanned content came from THIS producer.
fn producerRender(buf: *const DumbBuffer, seed: u32) void {
    const px: [*]volatile u32 = buf.map.?;
    const row = buf.pitch / 4;
    const w = buf.width;
    const h = buf.height;
    // window rect, centred, ~70% of screen
    const wx0 = w / 6;
    const wy0 = h / 5;
    const wx1 = w - wx0;
    const wy1 = h - wy0;
    const titleH = 64;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var c: u32 = 0x00101020; // desktop
            if (x >= wx0 and x < wx1 and y >= wy0 and y < wy1) {
                if (y < wy0 + titleH) {
                    c = 0x003040C0; // title bar
                } else {
                    // client gradient shifts with seed -> producer-owned
                    const gx = x - wx0;
                    const gy = y - wy0 - titleH;
                    c = @as(u32, 0x00200000) |
                        (@as(u32, gx * 255 / (wx1 - wx0)) << 16) |
                        (@as(u32, (gy + seed * 7) * 255 / (wy1 - wy0)) << 8) |
                        @as(u32, 0x80);
                }
            }
            // three "window dots" top-left of title bar
            if (y >= wy0 + 16 and y < wy0 + 48 and
                (x == wx0 + 24 or x == wx0 + 56 or x == wx0 + 88))
                c = 0x00FFFFFF;
            px[@as(usize, @intCast(y)) * @as(usize, @intCast(row)) +
                @as(usize, @intCast(x))] = c;
        }
    }
    stage("kms: producer rendered into dmabuf (no i915 regs touched)");
}

// runDmabuf: the M3 demo — producer renders, exports token; display
// imports, atomic-flips, collects vblank. Requires live 'kms' modeset.
pub fn runDmabuf() void {
    stage("kms: ==== M3 dmabuf producer->scanout ====");
    if (!probe()) return;
    if (gdev.scanout == null) {
        stage("kms: no live scanout — run 'kms' first");
        return;
    }
    // 1. PRODUCER: create shareable buffer + render content into it.
    const tok = dmabufCreate(1920, 1080) orelse return;
    const pbuf = dmabufMap(tok) orelse {
        stage("kms: FAIL dmabufMap — producer lost its buffer");
        dmabufUnref(tok);
        return;
    };
    producerRender(pbuf, 3);
    // 2. HANDOFF: display imports the token (the compositor seam).
    const h = dmabufImport(tok) orelse {
        dmabufUnref(tok);
        return;
    };
    // 3. DISPLAY: atomic check->test->commit pageflip of the imported buf.
    if (!flipCommit(h)) {
        dmabufUnref(tok); // drop importer ref
        return;
    }
    _ = vblankWait(2);
    // 4. LIFETIME: producer drops its ref; display ref keeps it alive
    //    while scanned. Buffer stays live until next flip/unref.
    dmabufUnref(tok); // producer done -> refs 2->1 (display still holds)
    text.puts("KORU M3 dmabuf live — producer->scanout decoupled\n");
    stage("kms: ==== M3 dmabuf complete ====");
}
