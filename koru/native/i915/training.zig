// koru/native i915/training — DP link training,
// ported from libgfxinit common/hw-gfx-dp_training.adb (coreboot,
// GPL-2.0), reduced to DIGI_A/eDP with the DDI callbacks from ddi.zig.

const mmio = @import("mmio.zig");
const dp = @import("dp.zig");
const ddi = @import("ddi.zig");

fn laneCount(link: dp.DPLink) usize {
    return @intCast(dp.laneCountInt(link.laneCount));
}

fn trainingSetByte(vs: u8, emph: u8) u8 {
    var v: u8 = vs; // VS_Level_n -> n
    if (vs == ddi.maxVSwing()) v |= 0x04;
    v |= emph << 3; // Emph_Level_n -> n<<3
    if (emph == ddi.maxPreEmph(vs)) v |= 0x20;
    return v;
}

fn sinkInit(link: dp.DPLink) bool {
    // Link_Rate_As_Word8: DP_Bandwidth representation 6/10/20.
    const bwByte: u8 = switch (link.bandwidth) {
        .b1_62 => 6, .b2_7 => 10, .b5_4 => 20,
    };
    var data: [2]u8 = .{ bwByte, @intCast(laneCount(link)) };
    if (link.enhancedFraming) data[1] |= 0x80;
    if (!dp.auxWrite(dp.DP_A, 0x00100, &data)) return link.opportunisticTraining;
    data = .{ 0, 1 }; // no downspread, ANSI8B10B
    if (!dp.auxWrite(dp.DP_A, 0x00107, &data)) return link.opportunisticTraining;
    return true;
}

const TP1: u8 = 1;
const TP2: u8 = 2;
const TP3: u8 = 3;
const TP_IDLE: u8 = 4;
const TP_NONE: u8 = 4; // TP_Idle and TP_None share index in the Ada enum tail

fn sinkSetTrainingPattern(link: dp.DPLink, pattern: u8, ts: u8) bool {
    const tp: u8 = switch (pattern) {
        TP1 => 0x21,
        TP2 => 0x22,
        TP3 => 0x23,
        else => 0, // TP_Idle / TP_None
    };
    var data: [5]u8 = @splat(0);
    data[0] = tp;
    var len: usize = 1;
    if (pattern < TP_IDLE) { // pattern < TP_Idle: append per-lane T_Set
        const n = laneCount(link);
        var i: usize = 0;
        while (i < n) : (i += 1) data[1 + i] = ts;
        len = 1 + n;
    }
    return dp.auxWrite(dp.DP_A, 0x00102, data[0..len]);
}

fn sinkSetSignalLevels(link: dp.DPLink, ts: u8) bool {
    var data: [4]u8 = @splat(0);
    const n = laneCount(link);
    var i: usize = 0;
    while (i < n) : (i += 1) data[i] = ts;
    return dp.auxWrite(dp.DP_A, 0x00103, data[0..n]);
}

const TrainSet = struct { vs: u8, emph: u8 };

fn sinkAdjustTraining(
    link: dp.DPLink,
    ts: *TrainSet,
    crDone: *bool,
    eqDone: *bool,
    success: *bool,
) void {
    const st = dp.readLinkStatus(dp.DP_A) orelse {
        success.* = false;
        return;
    };
    const crWasDone = crDone.*;
    crDone.* = dp.allCRDone(st, link);
    eqDone.* = dp.allEQDone(st, link);
    success.* = success.* and (crDone.* or !crWasDone);

    // Voltage swing may update during EQ too.
    if (success.* and !eqDone.*) {
        ts.vs = @min(dp.maxRequestedVS(st, link), ddi.maxVSwing());
    }
    // Linux accepts new preemph any time; so do we.
    if (success.* and !eqDone.*) {
        ts.emph = @min(dp.maxRequestedEmph(st, link), ddi.maxPreEmph(ts.vs));
    }
}

// Train_DP: full CR->EQ sequence. Returns true on EQ_Done.
pub fn trainDP(link: dp.DPLink) bool {
    mmio.say("i915: trainDP start\n");

    var ts = TrainSet{ .vs = 0, .emph = 0 };
    const eqPattern: u8 = if (link.rx.tps3Supported) TP3 else TP2; // TPS3_Supported=True for DDI

    var success = true;
    // TP1 + initial signal levels
    ddi.setTrainingPattern(link, TP1);
    ddi.setSignalLevels(link, ts.vs, ts.emph);
    success = sinkInit(link);
    if (success) success = sinkSetTrainingPattern(link, TP1, trainingSetByte(ts.vs, ts.emph));

    var crDone = false;
    var eqDone = false;
    if (success) {
        var retries: usize = 0;
        const maxRetry: usize = 4;
        var tries: usize = 0;
        while (tries < 32 and !crDone and success) : (tries += 1) {
            const delayUs: u64 = if (link.bandwidth == .b5_4 and link.rx.auxRdInterval != 0)
                @as(u64, link.rx.auxRdInterval) * 4000
            else
                100;
            mmio.sleepUs(delayUs);

            const lastTs = ts;
            sinkAdjustTraining(link, &ts, &crDone, &eqDone, &success);
            if (crDone or !success) break;

            if (ts.vs == lastTs.vs) {
                if (retries == maxRetry) break;
                retries += 1;
            } else {
                if (lastTs.vs == ddi.maxVSwing()) break;
                retries = 0;
            }
            ddi.setSignalLevels(link, ts.vs, ts.emph);
            success = sinkSetSignalLevels(link, trainingSetByte(ts.vs, ts.emph));
        }
    }
    success = success and crDone;
    mmio.say("i915: trainDP CR done="); mmio.say(mmio.yn(crDone));
    mmio.say(" success="); mmio.say(mmio.ynl(success));

    if (success) {
        ddi.setTrainingPattern(link, eqPattern);
        success = sinkSetTrainingPattern(link, eqPattern, trainingSetByte(ts.vs, ts.emph));
    }
    if (success) {
        var tries: usize = 0;
        while (tries < 6 and !eqDone and success) : (tries += 1) {
            const delayUs: u64 = if (link.rx.auxRdInterval != 0)
                @as(u64, link.rx.auxRdInterval) * 4000
            else
                400;
            mmio.sleepUs(delayUs);
            sinkAdjustTraining(link, &ts, &crDone, &eqDone, &success);
            if (eqDone or !success) break;
            ddi.setSignalLevels(link, ts.vs, ts.emph);
            success = sinkSetSignalLevels(link, trainingSetByte(ts.vs, ts.emph));
        }
    }

    // Sink first, then idle->normal on the port.
    _ = sinkSetTrainingPattern(link, TP_NONE, trainingSetByte(ts.vs, ts.emph));
    ddi.setTrainingPattern(link, TP_NONE);

    const ok = success and eqDone;
    mmio.say("i915: trainDP EQ done="); mmio.say(mmio.yn(eqDone));
    mmio.say(" -> "); mmio.say(if (ok) @as([*:0]const u8,"PASS\n") else @as([*:0]const u8,"FAIL\n"));
    if (!ok) ddi.digitalOff();
    return ok;
}
