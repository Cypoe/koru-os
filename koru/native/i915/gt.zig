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

const GTT_BASE_SLOT: u32 = 0x8000; // GTT page index — far above scanout PTEs
const PROOF_MAGIC: u32 = 0xc0de_0001;

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

fn forcewake(name: [*:0]const u8, setReg: u32, ackReg: u32) bool {
    const before = mmio.rd(ackReg);
    mmio.wr(setReg, mmio.rd(setReg) | 1);
    var ok = false;
    var i: u32 = 0;
    while (i < 50000) : (i += 1) {
        if ((mmio.rd(ackReg) & 1) != 0) {
            ok = true;
            break;
        }
        asm volatile ("pause");
    }
    mmio.say("gt: fw "); mmio.say(name); mmio.say(" ack ");
    mmio.sayHex(before); mmio.say("->");
    mmio.sayHex(mmio.rd(ackReg));
    if (ok) mmio.say(" OK\n") else mmio.say(" TIMEOUT\n");
    return ok;
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

    if (anyOk) {
        stage("gt: ==== SUBMISSION PROVEN — ring head advanced ====");
    } else {
        stage("gt: ==== SUBMISSION NOT PROVEN — see fin regs ====");
    }
    text.puts("gt: probe done\n");
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
