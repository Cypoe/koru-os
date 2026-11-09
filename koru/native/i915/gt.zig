// koru/native i915/gt — GEN9 render-engine (GT) probe.
//
// Oracle-method bring-up of the command streamer, staged and instrumented:
//   gt0  forcewake domains (RENDER/GT/MEDIA) + DC_STATE_EN disable
//   gt1  GGTT ring + hwsp + proof pages
//   gt2  ring regs (BCS then RCS): start/ctl/head/tail/hwsp/mode/imr
//   gt3  submit N MI_NOOPs + one MI_STORE_DWORD_IMM|GGTT magic write
//   gt4  poll head==tail, dump instdone/ipehr/acthd/exc/id, read proof
//
// Protocol reference: Linux i915 (gt/intel_engine_regs.h,
// gt/intel_execlists_submission.c, gt/intel_lrc*.c, i915_reg.h,
// gt/intel_gt_regs.h, display/intel_display_power_well.c,
// gt/intel_gpu_commands.h) — read as PROTOCOL, not ported.
//
// HONEST LIMITS of this probe:
//   - Direct ring submission (no execlists context). Gen8+ normally goes
//     through ELSP context descriptors; whether the CS will fetch a
//     hand-programmed ring with no context loaded is exactly what gt3/gt4
//     measures. If head never moves, the next rung is a minimal LRC
//     context image (gen9_xcs_offsets decoded in NOTES).
//   - No uC firmware loaded. Basic MI commands are expected to pass
//     through; if the engine faults, uc/ is the next suspect.
//   - MI_STORE_DWORD_IMM|MI_USE_GGTT targets GGTT space so it needs no
//     context PDP — the one memory op legal without a context.

const std = @import("std");
const mmio = @import("mmio.zig");
const R = mmio.R;
const pmm = @import("pmm");
const net = @import("net");
const pci = @import("pci");
const hostmmio = @import("mmio");
const led = @import("../led.zig");
const text = @import("../text.zig");
const kms = @import("kms.zig");

extern var stdout: ?*anyopaque;
extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;

// sayU — dual-write one formatted line: serial AND the UDP mirror, same
// discipline as cursor.zig/mouse.zig. The T590 oracle lives on the wire;
// mmio.say alone never reaches 192.168.99.1.
fn sayU(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    buf[s.len] = 0;
    _ = fputs(@ptrCast(&buf), stdout);
    net.mirror(s);
}

fn stage(comptime msg: [*:0]const u8) void {
    mmio.say(msg); mmio.say("\n");
    net.mark(std.mem.sliceTo(msg, 0));
    led.blink();
}

// ---- registers not already in regs.zig ------------------------------------
// (regs.zig carries the legacy RING_BUFFER_* names for RCS/VCS/BCS tails;
//  the per-engine block layout below is the gen8+ intel_engine_regs.h map.)
const OFF_TAIL: u32 = 0x030;
const OFF_HEAD: u32 = 0x034;
const OFF_START: u32 = 0x038;
const OFF_CTL: u32 = 0x03c;
const OFF_EXCC: u32 = 0x028;
const OFF_IPEIR: u32 = 0x064;
const OFF_IPEHR: u32 = 0x068;
const OFF_INSTDONE: u32 = 0x06c;
const OFF_ACTHD: u32 = 0x074;
const OFF_HWS_PGA: u32 = 0x080;
const OFF_ID: u32 = 0x08c;
const OFF_NOPID: u32 = 0x094;
const OFF_MI_MODE: u32 = 0x09c;
const OFF_IMR: u32 = 0x0a8;

const HEAD_ADDR_MASK: u32 = 0x001f_ffff; // HEAD_ADDR field (wrap count in high bits)
const RING_CTL_SIZE_MASK: u32 = 0x001f_f000; // RING_NR_PAGES field
const RING_VALID: u32 = 0x1;

// forcewake domains (intel_gt_regs.h, IS_GRAPHICS_VER 9..10 path)
const FW_RENDER_SET: u32 = 0x000a_278; // FORCEWAKE_RENDER_GEN9
const FW_RENDER_ACK: u32 = 0x0000_0d84; // FORCEWAKE_ACK_RENDER_GEN9
const FW_GT_SET: u32 = 0x000a_188; // FORCEWAKE_GT_GEN9
const FW_GT_ACK: u32 = 0x0013_0044; // FORCEWAKE_ACK_GT_GEN9
const FW_MEDIA_SET: u32 = 0x000a_270; // FORCEWAKE_MEDIA_GEN9
const FW_MEDIA_ACK: u32 = 0x0000_0d88; // FORCEWAKE_ACK_MEDIA_GEN9

const DC_STATE_EN: u32 = 0x0004_5504; // intel_display_regs.h
const PWRGT_STATUS: u32 = 0x000a_2a0; // GEN9_PWRGT_DOMAIN_STATUS
const PWRGT_RENDER_BIT: u32 = 1 << 1;
const PWRGT_MEDIA_BIT: u32 = 1 << 0;

// MI command dwords (intel_gpu_commands.h)
const MI_NOOP: u32 = 0x0000_0000;
const MI_BATCH_BUFFER_END: u32 = 0x0500_0000; // MI_INSTR(0x0a,0)
const MI_STORE_DWORD_IMM_GEN4_GGTT: u32 = 0x1040_0002; // 0x20<<23|2 | MI_USE_GGTT(1<<22)
const MI_FLUSH: u32 = 0x0200_0000; // MI_INSTR(0x04,0)
const MI_ARB_ON_OFF: u32 = 0x0400_0000; // MI_INSTR(0x08,0)
const MI_ARB_ENABLE: u32 = 1;
const MI_ARB_DISABLE: u32 = 0;
const MI_LRI_FORCE_POSTED: u32 = 1 << 12;

fn miLri(count: u32) u32 {
    // MI_LOAD_REGISTER_IMM(x) = MI_INSTR(0x22, 2x-1) = 0x22<<23 | (2x-1)
    return (0x22 << 23) | (2 * count - 1);
}

// gen9+ engine regs not already covered above (intel_engine_regs.h)
const OFF_ELSP: u32 = 0x230; // RING_ELSP — execlist context descriptor port
const OFF_PDP0_LDW: u32 = 0x270;
const PDP_STRIDE: u32 = 8;

// Context descriptor flags (intel_lrc.h / intel_lrc.c lrc_descriptor)
const GEN8_CTX_VALID: u64 = 1 << 0;
const GEN8_CTX_FORCE_RESTORE: u64 = 1 << 2; // CTX_DESC_FORCE_RESTORE
const GEN8_CTX_PRIVILEGE: u64 = 1 << 8;
const GEN8_CTX_ADDRESSING_MODE_SHIFT: u6 = 3;
const INTEL_LEGACY_32B_CONTEXT: u64 = 1; // 3-level PPGTT, 4GiB space

// BLT command dwords (intel_gpu_commands.h + intel_migrate.c emit_clear,
// the proven ver>=8 XY_COLOR_BLT emission — 7-dword command + NOOP pad)
const XY_COLOR_BLT_CMD: u32 = (2 << 29) | (0x50 << 22); // 0x54000000
const BLT_WRITE_RGBA: u32 = (1 << 20) | (2 << 20); // 0x300000
const BLT_DEPTH_32: u32 = 3 << 24;
const BLT_ROP_COLOR_COPY: u32 = 0xf0 << 16;

const GTT_BASE_SLOT: u32 = 0x8000; // GTT page index — far above scanout PTEs
const PROOF_MAGIC: u32 = 0xc0de_0001;
const BCS_BASE: u32 = 0x22000;

const Engine = struct {
    name: [*:0]const u8,
    base: u32,
};
const ENGINES = [_]Engine{
    .{ .name = "BCS", .base = 0x22000 }, // blitter — fewest state reqs
    .{ .name = "RCS", .base = 0x02000 }, // render — the real target later
};

var bar_ready = false;

fn ensureBar0() bool {
    if (bar_ready) return true;
    if (pci.count == 0) pci.init();
    const dev = pci.findClass(0x03, 0x00) orelse {
        stage("gt: FAIL no VGA-class device");
        return false;
    };
    if (dev.vendor != 0x8086) {
        stage("gt: FAIL gpu vendor");
        return false;
    }
    const bar0 = pci.barPhys(dev, 0);
    if (bar0 == 0) {
        stage("gt: FAIL BAR0 unmapped");
        return false;
    }
    mmio.setBase(bar0, bar0 + 0x80_0000);
    pci.setCommand(dev, pci.command(dev) | 0x6);
    bar_ready = true;
    mmio.say("gt: BAR0=");
    mmio.sayHex(bar0);
    mmio.say("\n");
    return true;
}

fn rdAt(base: u32, off: u32) u32 {
    return mmio.rd(base + off);
}
fn wrAt(base: u32, off: u32, v: u32) void {
    mmio.wr(base + off, v);
}

fn dumpEngine(comptime tag: [*:0]const u8, base: u32) void {
    mmio.say("gt: "); mmio.say(tag); mmio.say(" regs\n");
    const offs = [_]u32{ OFF_EXCC, OFF_IPEIR, OFF_IPEHR, OFF_INSTDONE,
        OFF_ACTHD, OFF_HEAD, OFF_TAIL, OFF_START, OFF_CTL, OFF_MI_MODE,
        OFF_IMR, OFF_ID, OFF_NOPID };
    const names = [_][*:0]const u8{ "EXCC", "IPEIR", "IPEHR", "INSTDONE",
        "ACTHD", "HEAD", "TAIL", "START", "CTL", "MIMODE", "IMR", "ID", "NOPID" };
    for (offs, names) |o, n| {
        mmio.say("  "); mmio.say(n); mmio.say("=");
        mmio.sayHex(rdAt(base, o)); mmio.say("\n");
    }
}

// Forcewake set-register format (intel_uncore.c fw_set/fw_clear +
// include/drm/intel/reg_bits.h REG_MASKED_FIELD): ONE dword write =
//   [31:16] bitmask of fields to touch, [15:0] values.
// fw_set(d, FORCEWAKE_KERNEL=BIT0) -> (1<<16)|1 = 0x00010001
// fw_clear(d, BIT0)               -> (1<<16)|0 = 0x00010000
// Fallback kick (WaRsForcewakeAddDelayForAck:skl,bxt,kbl,glk,cfl,cnl,icl):
//   set BIT15 -> (BIT15<<16)|BIT15 = 0x80008000 ; clear -> 0x80000000
const FW_SET_KERN: u32 = 0x0001_0001;
const FW_CLR_KERN: u32 = 0x0001_0000;
const FW_SET_FB: u32 = 0x8000_8000;
const FW_CLR_FB: u32 = 0x8000_0000;
const FW_ACK_TIMEOUT_MS: u32 = 50;

fn fwWait(ackReg: u32, bits: u32, wantSet: bool) bool {
    const deadline = mmio.nowMs() + FW_ACK_TIMEOUT_MS;
    while (mmio.nowMs() < deadline) {
        const a = mmio.rd(ackReg);
        if (wantSet) {
            if ((a & bits) == bits) return true;
        } else if ((a & bits) == 0) return true;
        asm volatile ("pause");
    }
    return false;
}

fn dumpFw(comptime tag: [*:0]const u8, setReg: u32, ackReg: u32) void {
    mmio.say("gt: "); mmio.say(tag); mmio.say(" set=");
    mmio.sayHex(mmio.rd(setReg)); mmio.say(" ack=");
    mmio.sayHex(mmio.rd(ackReg)); mmio.say("\n");
}

fn forcewake(name: [*:0]const u8, setReg: u32, ackReg: u32) bool {
    dumpFw("pre ", setReg, ackReg);
    // fw_domain_get: write mask/value pair, then poll ack bit0 (50ms).
    mmio.wr(setReg, FW_SET_KERN);
    dumpFw("req ", setReg, ackReg);
    if (fwWait(ackReg, 1, true)) {
        dumpFw("ack ", setReg, ackReg);
        mmio.say("gt: fw "); mmio.say(name); mmio.say(" OK (primary)\n");
        return true;
    }
    dumpFw("t/o ", setReg, ackReg);
    // WaRsForcewakeAddDelayForAck fallback: toggle bit15 to kick the
    // state machine; the lost bit0 ack rides along on retry (<=10 passes,
    // 10us*pass delay between).
    var pass: u32 = 1;
    var kicked = false;
    while (pass <= 10) : (pass += 1) {
        _ = fwWait(ackReg, 0x8000, false);
        mmio.wr(setReg, FW_SET_FB);
        mmio.sleepUs(10 * pass);
        _ = fwWait(ackReg, 0x8000, true);
        const a = mmio.rd(ackReg);
        kicked = (a & 1) != 0;
        mmio.wr(setReg, FW_CLR_FB);
        if (kicked) break;
    }
    dumpFw("fbk ", setReg, ackReg);
    if (kicked) {
        mmio.say("gt: fw "); mmio.say(name); mmio.say(" OK (fallback)\n");
        return true;
    }
    mmio.say("gt: fw "); mmio.say(name); mmio.say(" TIMEOUT\n");
    return false;
}

fn gtPower() bool {
    stage("gt0: forcewake domains");
    const r = forcewake("RENDER", FW_RENDER_SET, FW_RENDER_ACK);
    const g = forcewake("GT", FW_GT_SET, FW_GT_ACK);
    _ = forcewake("MEDIA", FW_MEDIA_SET, FW_MEDIA_ACK);

    stage("gt0: dc_state_en disable");
    const dc0 = mmio.rd(DC_STATE_EN);
    mmio.say("gt: DC_STATE_EN="); mmio.sayHex(dc0); mmio.say("\n");
    mmio.wr(DC_STATE_EN, 0); // DC_STATE_EN_UPTO_DC3CO_DC5_DC6_MASK=0 -> all off
    const dc1 = mmio.rd(DC_STATE_EN);
    mmio.say("gt: DC_STATE_EN now="); mmio.sayHex(dc1); mmio.say("\n");
    const st = mmio.rd(PWRGT_STATUS);
    mmio.say("gt: PWRGT_STATUS="); mmio.sayHex(st);
    mmio.say(" render="); mmio.say(mmio.yn((st & PWRGT_RENDER_BIT) != 0));
    mmio.say(" media="); mmio.say(mmio.yn((st & PWRGT_MEDIA_BIT) != 0));
    mmio.say("\n");
    return r and g; // media optional for BCS/RCS
}

// ---- memory -----------------------------------------------------------------

const Pages = struct {
    ringPhys: u64 = 0,
    ringGttSlot: u32 = 0,
    hwspPhys: u64 = 0,
    hwspGttSlot: u32 = 0,
    proofPhys: u64 = 0,
    proofGttSlot: u32 = 0,
};

fn mapGtt(phys: u64, bytes: u64, slot: u32) bool {
    const nPages: u32 = @intCast((bytes + 4095) / 4096);
    var i: u32 = 0;
    while (i < nPages) : (i += 1) {
        mmio.writeGtt(slot + i, phys + @as(u64, i) * 4096, true);
    }
    return hostmmio.map(phys, bytes);
}

fn allocPages(n: usize, align_frames: usize) ?u64 {
    return pmm.allocContiguous(n, align_frames);
}

fn setupMemory() ?Pages {
    var p = Pages{};
    // 8KiB ring (2 pages), 1 page hwsp, 1 page proof — contiguous not
    // required across objects, only within the ring.
    p.ringPhys = allocPages(2, 1) orelse {
        stage("gt1: FAIL ring alloc");
        return null;
    };
    p.hwspPhys = allocPages(1, 1) orelse {
        stage("gt1: FAIL hwsp alloc");
        return null;
    };
    p.proofPhys = allocPages(1, 1) orelse {
        stage("gt1: FAIL proof alloc");
        return null;
    };
    p.ringGttSlot = GTT_BASE_SLOT;
    p.hwspGttSlot = GTT_BASE_SLOT + 8;
    p.proofGttSlot = GTT_BASE_SLOT + 16;

    if (!mapGtt(p.ringPhys, 8192, p.ringGttSlot)) {
        stage("gt1: FAIL ring map");
        return null;
    }
    if (!mapGtt(p.hwspPhys, 4096, p.hwspGttSlot)) {
        stage("gt1: FAIL hwsp map");
        return null;
    }
    if (!mapGtt(p.proofPhys, 4096, p.proofGttSlot)) {
        stage("gt1: FAIL proof map");
        return null;
    }

    // CPU-side clear + ring command image.
    const ring: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(p.ringPhys)));
    var i: usize = 0;
    while (i < 2048) : (i += 1) ring[i] = MI_NOOP;

    // Command stream: NOOPs, one GGTT dword store of PROOF_MAGIC into the
    // proof page (GTT slot proofGttSlot -> gtt byte offset = slot*4096),
    // NOOPs, BATCH_BUFFER_END. tail = bytes consumed.
    const proofGttByte: u64 = @as(u64, p.proofGttSlot) * 4096;
    var dw: usize = 0;
    // 4 NOOPs then the store (16B aligned)
    ring[dw] = MI_NOOP; dw += 1;
    ring[dw] = MI_NOOP; dw += 1;
    ring[dw] = MI_NOOP; dw += 1;
    ring[dw] = MI_NOOP; dw += 1;
    ring[dw] = MI_STORE_DWORD_IMM_GEN4_GGTT; dw += 1;
    ring[dw] = @truncate(proofGttByte); dw += 1;          // addr lo
    ring[dw] = @truncate(proofGttByte >> 32); dw += 1;    // addr hi
    ring[dw] = PROOF_MAGIC; dw += 1;                      // data
    // pad to qword then NOOPs + end marker
    while (dw % 2 != 0) : (dw += 1) ring[dw] = MI_NOOP;
    ring[dw] = MI_NOOP; dw += 1;
    ring[dw] = MI_BATCH_BUFFER_END; dw += 1;
    while (dw % 2 != 0) : (dw += 1) ring[dw] = MI_NOOP;
    const tailBytes: u32 = @intCast(dw * 4);

    mmio.say("gt1: ring phys="); mmio.sayHex(p.ringPhys);
    mmio.say(" gtt_slot="); mmio.sayHex(p.ringGttSlot);
    mmio.say(" ring_gtt_off="); mmio.sayHex(@as(u64, p.ringGttSlot) * 4096);
    mmio.say(" tail="); mmio.sayDec(tailBytes); mmio.say("\n");
    mmio.say("gt1: hwsp phys="); mmio.sayHex(p.hwspPhys);
    mmio.say(" proof phys="); mmio.sayHex(p.proofPhys); mmio.say("\n");
    return p;
}

// ---- ring bring-up + submit --------------------------------------------------

fn ringReset(base: u32) void {
    // intel_gt.c init_unused_ring order: invalidate, then zero state.
    wrAt(base, OFF_CTL, 0);
    wrAt(base, OFF_HEAD, 0);
    wrAt(base, OFF_TAIL, 0);
    wrAt(base, OFF_START, 0);
    mmio.postingRead(base + OFF_CTL);
}

fn ringArm(base: u32, ringGttOff: u64, ringBytes: u32, hwspGttOff: u64, tail: u32) void {
    wrAt(base, OFF_HWS_PGA, @truncate(hwspGttOff));
    wrAt(base, OFF_IMR, 0xffff_ffff); // mask all engine interrupts — we poll
    // MI_MODE: clear STOP_RING (bit8); preserve nothing else we care about.
    wrAt(base, OFF_MI_MODE, rdAt(base, OFF_MI_MODE) & ~(@as(u32, 1) << 8));
    wrAt(base, OFF_START, @truncate(ringGttOff));
    // RING_CTL = (pages-1)<<12 | VALID ; 8KiB = 2 pages -> 1<<12 | 1
    const pagesM1: u32 = (ringBytes / 4096) - 1;
    wrAt(base, OFF_CTL, (pagesM1 << 12) | RING_VALID);
    mmio.postingRead(base + OFF_CTL);
    // Arm the tail LAST — this is the kick.
    wrAt(base, OFF_TAIL, tail);
}

fn tryEngine(e: Engine, p: Pages) bool {
    stage("gt2: ring arm ");
    mmio.say(e.name); mmio.say("\n");
    const base = e.base;

    dumpEngine("pre ", base);
    ringReset(base);
    ringArm(base, @as(u64, p.ringGttSlot) * 4096, 8192,
            @as(u64, p.hwspGttSlot) * 4096, ringTailBytes());

    stage("gt3: submitted ");
    mmio.say(e.name); mmio.say("\n");
    dumpEngine("post ", base);

    // Poll head for up to ~250ms.
    const want = ringTailBytes() & HEAD_ADDR_MASK;
    var head: u32 = 0;
    var i: u32 = 0;
    while (i < 250000) : (i += 1) {
        head = rdAt(base, OFF_HEAD) & HEAD_ADDR_MASK;
        if (head == want) break;
        asm volatile ("pause");
    }
    mmio.say("gt4: "); mmio.say(e.name); mmio.say(" head=");
    mmio.sayHex(head); mmio.say(" want="); mmio.sayHex(want);
    if (head == want) mmio.say(" SUBMIT-OK\n") else mmio.say(" HEAD-STALLED\n");
    dumpEngine("fin  ", base);
    return head == want;
}

var tail_bytes: u32 = 0;
fn ringTailBytes() u32 {
    return tail_bytes;
}

// ---- public probe -------------------------------------------------------------

pub fn probe() void {
    text.puts("gt: render-engine probe — watch UDP markers\n");
    if (!ensureBar0()) return;

    stage("gt: ==== GEN9 render-engine probe begin ====");

    if (!gtPower()) {
        stage("gt: FAIL power domains");
        return;
    }
    stage("gt0: power domains up");

    const p = setupMemory() orelse return;
    stage("gt1: gtt ring+hwsp+proof mapped");

    // Fill command image tail size — recompute what setupMemory laid down
    // by re-reading the stream: it ends after BATCH_BUFFER_END + pad.
    // (setupMemory computed it; stash via rescan is fragile — store it.)
    tail_bytes = computeTail(p);

    var anyOk = false;
    for (ENGINES) |e| {
        if (tryEngine(e, p)) anyOk = true;
    }

    // CPU readback of the proof page — did the GPU's GGTT store land?
    const proof: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(p.proofPhys)));
    mmio.say("gt4: proof[0]="); mmio.sayHex(proof[0]);
    if (proof[0] == PROOF_MAGIC) mmio.say(" GPU-WRITE-OK\n") else mmio.say(" no-gpu-write\n");

    // blit phase: minimal LRC + ELSP + XY_COLOR_BLT on BCS (gt5 markers)
    blitPhase(p);

    if (anyOk) {
        stage("gt: ==== SUBMISSION PROVEN — ring head advanced ====");
    } else {
        stage("gt: ==== SUBMISSION NOT PROVEN — see fin regs ====");
    }
    text.puts("gt: probe done\n");
}

// ---- blit phase: minimal LRC context + ELSP submit + XY_COLOR_BLT ----------
// Oracle: linux i915 gt/intel_lrc.c (gen9_xcs_offsets, lrc_descriptor,
// lrc_update_regs, init_common_regs/init_ppgtt_regs/__reset_stop_ring),
// gt/intel_execlists_submission.c (write_desc -> RING_ELSP UDW-then-LDW,
// emit_pdps), gt/gen8_ppgtt.c + gt/intel_gtt.h (gen8_pte/pde_encode),
// gt/intel_gpu_commands.h + gt/intel_migrate.c emit_clear (XY_COLOR_BLT).

// gen9_xcs_offsets[] verbatim from intel_lrc.c (u8-encoded reg-state
// template). NOP(x)=0x80|x skips x dwords; LRI(c,posted)=(posted?0x40:0)|c;
// REG/REG16 are varint-encoded MMIO byte offsets (decoded <<2).
const gen9_xcs_offsets = [_]u8{
    0x81, // NOP(1)
    0x4e, // LRI(14, POSTED)
    0x81, 0x11, 0x0d, 0x0c, 0x0e, 0x0f, 0x5a, 0x50, 0x44, 0x47, 0x45,
    0x46, 0x70, 0x71, 0x72, // 14 regs: CTX_CTRL,HEAD,TAIL,START,CTL,BB*,INDIR*
    0x83, // NOP(3)
    0x49, // LRI(9, POSTED)
    0x81, 0x6a, 0x81, 0x23, 0x81, 0x22, 0x81, 0x21, 0x81, 0x20, 0x81,
    0x1f, 0x81, 0x1e, 0x81, 0x1d, 0x81, 0x1c, // TS,PDP3..PDP0 UDW/LDW
    0x8d, // NOP(13)
    0x41, // LRI(1, POSTED)
    0x81, 0x00, // +0x200
    0x8d, // NOP(13)
    0x6c, // LRI(44, POSTED)
    0x0a, 0x27, 0x30, 0x5e, 0x5f, 0x81, 0x56, 0x5c, 0x54, 0x55, 0x56,
    0x82, 0x07, // +0x41c
    0x83, 0x00, 0x83, 0x01, 0x83, 0x02, 0x83, 0x03, 0x83, 0x04, 0x83,
    0x05, 0x83, 0x06, 0x83, 0x07, 0x83, 0x08, 0x83, 0x09, 0x83, 0x0a,
    0x83, 0x0b, 0x83, 0x0c, 0x83, 0x0d, 0x83, 0x0e, 0x83, 0x0f, 0x83,
    0x10, 0x83, 0x11, 0x83, 0x12, 0x83, 0x13, 0x83, 0x14, 0x83, 0x15,
    0x83, 0x16, 0x83, 0x17, 0x83, 0x18, 0x83, 0x19, 0x83, 0x1a, 0x83,
    0x1b, 0x83, 0x1c, 0x83, 0x1d, 0x83, 0x1e, 0x83, 0x1f, // GPRs 0x600+
    0x1a, // +0x068
    0x00, // END
};

const LRC_STATE_PAGE: usize = 1; // page 1 of ctx object = reg-state image

// Decode the u8 template into MI_LOAD_REGISTER_IMM commands in dst[].
// Returns dwords used (incl. BATCH_BUFFER_END terminator).
fn buildLrcImage(dst: [*]u32, engineBase: u32) usize {
    var r: usize = 0;
    var di: usize = 0;
    const data = &gen9_xcs_offsets;
    while (data[di] != 0) {
        const b = data[di];
        di += 1;
        if ((b & 0x80) != 0) { // NOP skip
            r += b & 0x7f;
            continue;
        }
        const count: u32 = b & 0x3f;
        const posted = (b & 0x40) != 0;
        var cmd = miLri(count);
        if (posted) cmd |= MI_LRI_FORCE_POSTED;
        dst[r] = cmd;
        r += 1;
        var k: u32 = 0;
        while (k < count) : (k += 1) {
            var off: u32 = 0;
            while (true) {
                const v = data[di];
                di += 1;
                off = (off << 7) | (v & 0x7f);
                if ((v & 0x80) == 0) break;
            }
            dst[r] = engineBase + (off << 2);
            r += 2; // addr dword + value dword
        }
    }
    dst[r] = MI_BATCH_BUFFER_END;
    r += 1;
    return r;
}

// Patch (addr,value) slots in the built image. vals keyed by engine-rel off.
fn lrcPatch(dst: [*]u32, used: usize, engineBase: u32, off: u32, val: u32) void {
    const want = engineBase + off;
    var j: usize = 0;
    while (j + 1 < used) : (j += 1) {
        if (dst[j] == want) dst[j + 1] = val;
    }
}

const BLT_RED: u32 = 0xffff_0000;
const BLT_MAGENTA: u32 = 0xffff_00ff;
const STRIPE_DWORDS: u32 = 32;

// Compact one-line engine dump that reaches the UDP wire (sayU). PDP0 and
// CTXCTL are the context discriminators: the LRC image sets PDP0=pdPhys
// and CONTEXT_CONTROL=0x8; a bare/GGTT run leaves them at whatever the
// last writer left — comparing gt5b vs gt5a dumps shows whether the
// execlist context actually took.
fn dumpEngineU(comptime tag: []const u8, base: u32) void {
    sayU("gt5: {s} EXCC={x} IPEIR={x} IPEHR={x} INSTDONE={x} ACTHD={x} HEAD={x} TAIL={x} START={x} CTL={x} MIMODE={x} IMR={x} ID={x} PDP0={x} CTXCTL={x}\n", .{
        tag, rdAt(base, OFF_EXCC), rdAt(base, OFF_IPEIR), rdAt(base, OFF_IPEHR),
        rdAt(base, OFF_INSTDONE), rdAt(base, OFF_ACTHD), rdAt(base, OFF_HEAD),
        rdAt(base, OFF_TAIL), rdAt(base, OFF_START), rdAt(base, OFF_CTL),
        rdAt(base, OFF_MI_MODE), rdAt(base, OFF_IMR), rdAt(base, OFF_ID),
        rdAt(base, OFF_PDP0_LDW), rdAt(base, 0x244) });
}

fn pollHead(base: u32, want: u32, ms: u32) u32 {
    const deadline = mmio.nowMs() + ms;
    var head: u32 = 0;
    while (mmio.nowMs() < deadline) {
        head = rdAt(base, OFF_HEAD) & HEAD_ADDR_MASK;
        if (head == want) return head;
        asm volatile ("pause");
    }
    return head;
}

// emitBltBatch — one ring image shared by both phases:
//   [NOOP] [optional emit_pdps preamble] [XY_COLOR_BLT red rect]
//   [MI_STORE_DWORD_IMM|GGTT x32 magenta stripe] [BATCH_BUFFER_END] [pad]
// The stripe runs AFTER the blt and lives near the TOP of the buffer
// (row 8) while the blt targets the BOTTOM pages — no overlap on the
// 1080p scanout, so magenta survives as an independent write proof.
// dstLo/dstHi = the blt destination in the CURRENT address space:
//   phase B (bare ring): GGTT byte offset of the target phys pages.
//   phase A (LRC ctx):   PPGTT VA 0 (PT maps VA0 -> buf.phys+startByte).
fn emitBltBatch(ring: [*]volatile u32, pdpPre: bool, base: u32,
                pdLo: u32, pdHi: u32,
                dstLo: u32, dstHi: u32,
                pitch: u32, rows: u32, widthDw: u32,
                gttStripe: u64) usize {
    var dw: usize = 0;
    ring[dw] = MI_NOOP; dw += 1;
    if (pdpPre) {
        ring[dw] = MI_ARB_ON_OFF | MI_ARB_DISABLE; dw += 1;
        ring[dw] = MI_NOOP; dw += 1;
        ring[dw] = miLri(8) | MI_LRI_FORCE_POSTED; dw += 1;
        var pdp: u32 = 3;
        while (true) : (pdp -= 1) {
            const a = base + OFF_PDP0_LDW + pdp * PDP_STRIDE;
            ring[dw] = a + 4; ring[dw + 1] = pdHi; dw += 2; // UDW
            ring[dw] = a; ring[dw + 1] = pdLo; dw += 2; // LDW
            if (pdp == 0) break;
        }
        ring[dw] = MI_ARB_ON_OFF | MI_ARB_ENABLE; dw += 1;
    }
    // XY_COLOR_BLT ver>=8 layout (intel_migrate.c emit_clear):
    //   DW1 = DEPTH_32|ROP_COLOR_COPY|pitch ; DW2 = origin(0)
    //   DW3 = (rows<<16)|width_dw ; DW4/DW5 = dst addr ; DW6 = color
    ring[dw] = XY_COLOR_BLT_CMD | BLT_WRITE_RGBA | 5; dw += 1; // (7-2)
    ring[dw] = BLT_DEPTH_32 | BLT_ROP_COLOR_COPY | pitch; dw += 1;
    ring[dw] = 0; dw += 1;
    ring[dw] = (rows << 16) | widthDw; dw += 1;
    ring[dw] = dstLo; dw += 1;
    ring[dw] = dstHi; dw += 1;
    ring[dw] = BLT_RED; dw += 1;
    ring[dw] = MI_NOOP; dw += 1;
    var i: u32 = 0;
    while (i < STRIPE_DWORDS) : (i += 1) {
        const a = gttStripe + @as(u64, i) * 4;
        ring[dw] = MI_STORE_DWORD_IMM_GEN4_GGTT; dw += 1;
        ring[dw] = @truncate(a); dw += 1;
        ring[dw] = @truncate(a >> 32); dw += 1;
        ring[dw] = BLT_MAGENTA; dw += 1;
    }
    ring[dw] = MI_BATCH_BUFFER_END; dw += 1;
    while (dw % 2 != 0) : (dw += 1) ring[dw] = MI_NOOP;
    return dw;
}

// readback — sample the blt region + stripe row, every value on the wire.
// round 0 = immediately after head==want (pre-compositor), round 1 =
// +200ms later. red->0 between rounds = the GPU wrote and the
// compositor erased it — that IS the visible-rect proof.
fn readback(tag: []const u8, buf: kms.DumbBuffer, startByte: u64,
             rows: u32, pitch: u32, round: u32) void {
    const px = buf.map orelse {
        sayU("gt5: {s} no cpu map\n", .{tag});
        return;
    };
    const regionBytes: u64 = @as(u64, rows) * pitch;
    const rowDw: u64 = pitch / 4;
    _ = rowDw;
    var red: u32 = 0;
    var n: u32 = 0;
    const fracs = [_]u64{ 1, 3, 5, 7 };
    const tenth = regionBytes / 10;
    for (fracs) |f| {
        const rb = tenth * f;
        const cols = [_]u64{ 64, pitch / 2, pitch - 64 };
        for (cols) |colB| {
            const byteOff = startByte + rb + colB;
            const idx: usize = @intCast(byteOff / 4);
            const v = px[idx];
            n += 1;
            // XRGB-ish red: R=ff G=0 B=0, any alpha
            if ((v & 0x00ff0000) == 0x00ff0000 and (v & 0x0000ff00) == 0 and
                (v & 0x000000ff) == 0) red += 1;
            sayU("gt5: {s} r{d} f{d} px={x}\n", .{ tag, round, n, v });
        }
    }
    // stripe probes: row 8, cols 100..131 step 8
    const sBase: u64 = @as(u64, 8) * pitch + 100 * 4;
    var mag: u32 = 0;
    const ks = [_]u64{ 0, 8, 16, 24 };
    for (ks) |k| {
        const idx: usize = @intCast(sBase / 4 + k);
        const v = px[idx];
        if ((v & 0x00ff0000) == 0x00ff0000 and (v & 0x000000ff) == 0xff and
            (v & 0x0000ff00) == 0) mag += 1;
        sayU("gt5: {s} r{d} st{d} px={x}\n", .{ tag, round, k, v });
    }
    sayU("gt5: {s} round{d} red={d}/12 mag={d}/4\n", .{ tag, round, red, mag });
}

// phase B — bare ring, NO execlist context: the engine's current address
// space is whatever a context-free gen9 CS defaults to (expected GGTT).
// dst = the scanout's GGTT byte offset, so if GGTT addressing is live the
// blt lands on scanned phys directly. Runs BEFORE any ELSP submit — once
// a context loads it may persist and change the meaning of dst.
fn blitBare(p: Pages, buf: kms.DumbBuffer, startByte: u64,
             rows: u32, pitch: u32, widthDw: u32) void {
    const base = BCS_BASE;
    stage("gt5b: ==== bare-ring GGTT blit begin ====");
    const ring: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(p.ringPhys)));
    var zi: usize = 0;
    while (zi < 2048) : (zi += 1) ring[zi] = MI_NOOP;
    const gttDst = buf.gtt_offset + startByte;
    const gttStripe = buf.gtt_offset + @as(u64, 8) * pitch + 400;
    const dw = emitBltBatch(ring, false, base, 0, 0,
        @truncate(gttDst), @truncate(gttDst >> 32),
        pitch, rows, widthDw, gttStripe);
    const tailB: u32 = @intCast(dw * 4);
    sayU("gt5b: dst_gtt={x} stripe_gtt={x} tail={x} rows={d}\n", .{
        gttDst, gttStripe, tailB, rows });
    ringReset(base);
    wrAt(base, OFF_HWS_PGA, @truncate(@as(u64, p.hwspGttSlot) * 4096));
    wrAt(base, OFF_IMR, 0xffff_ffff);
    wrAt(base, OFF_MI_MODE, rdAt(base, OFF_MI_MODE) & ~(@as(u32, 1) << 8));
    wrAt(base, OFF_START, @truncate(@as(u64, p.ringGttSlot) * 4096));
    wrAt(base, OFF_CTL, 0x1001);
    mmio.postingRead(base + OFF_CTL);
    wrAt(base, OFF_TAIL, tailB); // tail LAST — the kick
    stage("gt5b: submitted — polling head");
    const want = tailB & HEAD_ADDR_MASK;
    const head = pollHead(base, want, 1500);
    sayU("gt5b: head={x} want={x}\n", .{ head, want });
    if (head == want) {
        stage("gt5b: SUBMIT-OK");
    } else {
        stage("gt5b: HEAD-STALLED");
    }
    dumpEngineU("gt5b", base);
    readback("gt5b", buf, startByte, rows, pitch, 0);
    mmio.sleepUs(200000);
    readback("gt5b", buf, startByte, rows, pitch, 1);
}

// phase A — LRC context + ELSP, PPGTT addressing. Same blt image but dst
// is PPGTT VA 0; the PT maps VA0 -> buf.phys + startByte (bottom pages,
// away from console damage). If the context loads, this is the real
// gen8+ path; if gt5b already proved GGTT, this confirms PPGTT too.
fn blitLrc(p: Pages, buf: kms.DumbBuffer, startByte: u64, startPage: u32,
            rows: u32, pitch: u32, widthDw: u32, nPages: u32) void {
    const base = BCS_BASE;
    stage("gt5a: ==== LRC+ELSP PPGTT blit begin ====");

    const ctxPhys = allocPages(2, 1) orelse {
        stage("gt5a: FAIL ctx alloc");
        return;
    };
    const pdPhys = allocPages(1, 1) orelse {
        stage("gt5a: FAIL pd alloc");
        return;
    };
    const ptPhys = allocPages(1, 1) orelse {
        stage("gt5a: FAIL pt alloc");
        return;
    };
    _ = hostmmio.map(pdPhys, 4096);
    _ = hostmmio.map(ptPhys, 4096);

    const ctxGttSlot = GTT_BASE_SLOT + 24;
    mmio.writeGtt(ctxGttSlot, ctxPhys, true);
    mmio.writeGtt(ctxGttSlot + 1, ctxPhys + 4096, true);
    const ctxGttOff: u64 = @as(u64, ctxGttSlot) * 4096;

    const ctxPages: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(ctxPhys)));
    const lrc: [*]u32 = @ptrFromInt(@as(usize, @intCast(ctxPhys + 4096)));
    const pd: [*]u64 = @ptrFromInt(@as(usize, @intCast(pdPhys)));
    const pt: [*]u64 = @ptrFromInt(@as(usize, @intCast(ptPhys)));

    var zi: usize = 0;
    while (zi < 2048) : (zi += 1) ctxPages[zi] = 0;

    // PPGTT: PD[0]->PT ; PT[i] -> buf.phys + (startPage+i)*4K | PRESENT|RW|PAT
    pd[0] = ptPhys | 3;
    var pi: u32 = 0;
    while (pi < nPages) : (pi += 1) {
        pt[pi] = (buf.phys + (@as(u64, startPage) + pi) * 4096) | 0x83;
    }
    stage("gt5a: lrc+pdpt built");

    const used = buildLrcImage(lrc, base);
    const ringGttOff: u32 = @truncate(@as(u64, p.ringGttSlot) * 4096);
    lrcPatch(lrc, used, base, 0x034, 0); // HEAD
    lrcPatch(lrc, used, base, 0x038, ringGttOff); // START (ggtt off)
    lrcPatch(lrc, used, base, 0x03c, 0x1001); // CTL = 1<<12|VALID
    lrcPatch(lrc, used, base, 0x244, 0x8); // CONTEXT_CONTROL
    lrcPatch(lrc, used, base, 0x09c, 0x0100_0000); // MI_MODE STOP_RING<<16
    const pdLo: u32 = @truncate(pdPhys);
    const pdHi: u32 = @truncate(pdPhys >> 32);
    lrcPatch(lrc, used, base, 0x28c, pdHi); // PDP3_UDW
    lrcPatch(lrc, used, base, 0x288, pdLo); // PDP3_LDW
    lrcPatch(lrc, used, base, 0x284, pdHi); // PDP2_UDW
    lrcPatch(lrc, used, base, 0x280, pdLo); // PDP2_LDW
    lrcPatch(lrc, used, base, 0x27c, pdHi); // PDP1_UDW
    lrcPatch(lrc, used, base, 0x278, pdLo); // PDP1_LDW
    lrcPatch(lrc, used, base, 0x274, pdHi); // PDP0_UDW
    lrcPatch(lrc, used, base, 0x270, pdLo); // PDP0_LDW
    sayU("gt5a: lrc {d}dw ctx_gtt={x} pdphys={x}\n", .{ used, ctxGttOff, pdPhys });

    // ring batch: emit_pdps + blt(dst VA 0) + stripe
    const ring: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(p.ringPhys)));
    var zi2: usize = 0;
    while (zi2 < 2048) : (zi2 += 1) ring[zi2] = MI_NOOP;
    const gttStripe = buf.gtt_offset + @as(u64, 8) * pitch + 400;
    const dw = emitBltBatch(ring, true, base, pdLo, pdHi, 0, 0,
        pitch, rows, widthDw, gttStripe);
    const tailA: u32 = @intCast(dw * 4);
    lrcPatch(lrc, used, base, 0x030, tailA); // TAIL = this batch's end

    // legacy arm too (cheap; LRC restore overwrites on ctx switch-in)
    ringReset(base);
    wrAt(base, OFF_HWS_PGA, @truncate(@as(u64, p.hwspGttSlot) * 4096));
    wrAt(base, OFF_IMR, 0xffff_ffff);
    wrAt(base, OFF_MI_MODE, rdAt(base, OFF_MI_MODE) & ~(@as(u32, 1) << 8));
    wrAt(base, OFF_START, ringGttOff);
    wrAt(base, OFF_CTL, 0x1001);
    mmio.postingRead(base + OFF_CTL);

    const desc: u64 = ctxGttOff |
        (INTEL_LEGACY_32B_CONTEXT << GEN8_CTX_ADDRESSING_MODE_SHIFT) |
        GEN8_CTX_VALID | GEN8_CTX_PRIVILEGE | GEN8_CTX_FORCE_RESTORE;
    sayU("gt5a: elsp desc={x}\n", .{desc});
    wrAt(base, OFF_ELSP, @truncate(desc >> 32)); // UDW first
    wrAt(base, OFF_ELSP, @truncate(desc)); // LDW commits
    stage("gt5a: elsp written — polling");

    const want = tailA & HEAD_ADDR_MASK;
    const head = pollHead(base, want, 1500);
    sayU("gt5a: head={x} want={x}\n", .{ head, want });
    if (head == want) {
        stage("gt5a: SUBMIT-OK");
    } else {
        stage("gt5a: HEAD-STALLED");
    }
    dumpEngineU("gt5a", base);
    readback("gt5a", buf, startByte, rows, pitch, 0);
    mmio.sleepUs(200000);
    readback("gt5a", buf, startByte, rows, pitch, 1);
}

fn blitPhase(p: Pages) void {
    stage("gt5: ==== blit-via-GPU begin ====");
    const base = BCS_BASE;
    _ = base;

    // dst = live kms scanout if present, else a fresh dumb buffer.
    var dstBuf: ?kms.DumbBuffer = null;
    var owned: ?u32 = null;
    const dev = kms.device();
    if (dev.up and dev.scanout != null) {
        dstBuf = dev.dumbs[dev.scanout.?];
    }
    if (dstBuf == null and dev.up) {
        if (kms.dumbCreate(256, 256, 32)) |h| {
            owned = h;
            dstBuf = dev.dumbs[h];
        } else {}
    }
    const buf = dstBuf orelse {
        stage("gt5: FAIL no dst buffer (run kms first)");
        return;
    };
    sayU("gt5: dst w={d} h={d} pitch={d} phys={x} gtt_off={x} frames={d}\n", .{
        buf.width, buf.height, buf.pitch, buf.phys, buf.gtt_offset, buf.frames });

    // Geometry: bottom ~250 rows of the buffer — far from the console
    // titlebar/text damage so the compositor can't erase the proof before
    // a frame flips. startByte is page-aligned so one PT covers it.
    const pitch: u32 = buf.pitch;
    if (pitch == 0 or buf.frames == 0) {
        stage("gt5: FAIL degenerate buffer");
        return;
    }
    const totalPages: usize = buf.frames;
    const startPage: u32 = if (totalPages > 520)
        @intCast(totalPages - 469) else 0;
    const availBytes: u64 = @as(u64, totalPages - @as(usize, startPage)) * 4096;
    var rows: u32 = @intCast(@min(availBytes / pitch, @as(u64, 250)));
    if (rows == 0) rows = 1;
    var nPages: u32 = @intCast((@as(u64, rows) * pitch + 4095) / 4096);
    const maxPages: u32 = @intCast(totalPages - @as(usize, startPage));
    if (nPages > maxPages) {
        nPages = maxPages;
        rows = @intCast((@as(u64, nPages) * 4096) / pitch);
        if (rows == 0) rows = 1;
    }
    if (nPages > 512) {
        rows = @intCast((512 * 4096) / pitch);
        if (rows == 0) rows = 1;
        nPages = @intCast((@as(u64, rows) * pitch + 4095) / 4096);
    }
    const widthDw: u32 = pitch / 4;
    const startByte: u64 = @as(u64, startPage) * 4096;
    sayU("gt5: geom startPage={d} startByte={x} rows={d} nPages={d} widthDw={d}\n", .{
        startPage, startByte, rows, nPages, widthDw });

    // baseline readback BEFORE any submit — what does the surface hold now?
    readback("gt5pre", buf, startByte, rows, pitch, 0);

    blitBare(p, buf, startByte, rows, pitch, widthDw);
    blitLrc(p, buf, startByte, startPage, rows, pitch, widthDw, nPages);

    if (owned) |h| _ = kms.dumbDestroy(h);
    stage("gt5: ==== blit probe done — see gt5b/gt5a markers ====");
}

fn computeTail(p: Pages) u32 {
    // Mirror of the emit sequence in setupMemory: count dwords through
    // BATCH_BUFFER_END + trailing pad. Deterministic — 4+4+1+1(+pad)=~12dw.
    // Safer: scan the ring for the end marker position at runtime.
    const ring: [*]const volatile u32 = @ptrFromInt(@as(usize, @intCast(p.ringPhys)));
    var dw: usize = 0;
    while (dw < 2048) : (dw += 1) {
        if (ring[dw] == MI_BATCH_BUFFER_END) {
            // tail = bytes through this dword, qword-padded
            var bytes: usize = (dw + 1) * 4;
            if (bytes % 8 != 0) bytes += 4;
            return @intCast(bytes);
        }
    }
    return 0;
}
