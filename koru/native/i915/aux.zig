// koru/native i915/aux — native AUX channel, ported from
// libgfxinit hw-gfx-gma-dp_aux_request.adb + hw-gfx-dp_aux_ch.adb
// (coreboot, GPL-2.0), reduced to DP_A on DDI_AUX_CTL_A/DATA_A_1..5.
//
// Config resolution for Gen=Skylake/PCH=Sunrise_Point:
//   Has_Type_C_Ports=false, Has_PCH_Aux_Channels=false
//   -> AUX_CH uses the "else" table: DDI_AUX_CTL_A + DDI_AUX_DATA_A_1..5.
//   Need_DP_Aux_Mutex=false (constant) -> no mutex traffic.
//   DP_AUX_CTL_2x_Clock=0 (no PCH aux, no GMCH rawclk).
// I2C-over-AUX (DDC/EDID path) is NOT ported — M0 reads modes from
// constants; add when EDID-via-AUX is needed.

const mmio = @import("mmio.zig");
const R = mmio.R;

// DP_Defs command nibbles
const DP_AUX_NATIVE_WRITE: u8 = 0x8;
const DP_AUX_NATIVE_READ: u8 = 0x9;

// DP_AUX_CTL bits
const SEND_BUSY: u32 = 1 << 31;
const DONE: u32 = 1 << 30;
const TIME_OUT_ERROR: u32 = 1 << 28;
const TIME_OUT_TIMER_MASK: u32 = 3 << 26;
const TIME_OUT_TIMER_600US: u32 = 1 << 26;
const RECEIVE_ERROR: u32 = 1 << 25;
const MESSAGE_SIZE_MASK: u32 = 31 << 20;
const MESSAGE_SIZE_SHIFT: u32 = 20;

pub var dbgCtl: u32 = 0;   // last AUX_CTL status word (diag)
pub var dbgReply: u8 = 0;  // last response byte0 (reply code in bits 5:4)

const CTL = R.DDI_AUX_CTL_A;
const DATA = [5]u32{ R.DDI_AUX_DATA_A_1, R.DDI_AUX_DATA_A_2, R.DDI_AUX_DATA_A_3, R.DDI_AUX_DATA_A_4, R.DDI_AUX_DATA_A_5 };

pub const AuxRequest = [20]u8;
pub const AuxResponse = [20]u8;

fn fillAuxRequest(cmd: u8, addr: u32, len: usize) AuxRequest {
    var req: AuxRequest = @splat(0);
    req[0] = (@as(u8, cmd) << 4) | @as(u8, @truncate(addr >> 16));
    req[1] = @truncate(addr >> 8);
    req[2] = @truncate(addr);
    req[3] = @intCast(len - 1);
    return req;
}

fn isAuxAck(resp: *const AuxResponse) bool {
    return (resp[0] & 0x30) == 0x00;
}
fn isAuxDefer(resp: *const AuxResponse) bool {
    return (resp[0] & 0x30) == 0x20;
}

// Aux_Request_Low: one shot at the hardware. Request is the 20-byte
// buffer (first 4 header + payload); Request_Length counts all bytes.
fn auxRequestLow(
    req: *const AuxRequest,
    reqLen: usize,
    resp: *AuxResponse,
    respLen: *usize,
) bool {
    resp.* = @splat(0);
    respLen.* = 0;

    if (mmio.isSet(CTL, SEND_BUSY)) return false;

    // pack request bytes into the 5 data regs, 4 bytes each,
    // big-endian within each dword (buf[i] -> bits (3-i)*8)
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const off = i * 4;
        if (off < reqLen) {
            const count = @min(4, reqLen - off);
            var v: u32 = 0;
            var j: usize = 0;
            while (j < count) : (j += 1)
                v |= @as(u32, req[off + j]) << @intCast((3 - j) * 8);
            mmio.wr(DATA[i], v);
        }
    }

    mmio.unsetAndSet(CTL,
        DONE | TIME_OUT_TIMER_MASK | MESSAGE_SIZE_MASK,
        SEND_BUSY | DONE | TIME_OUT_ERROR | RECEIVE_ERROR |
        TIME_OUT_TIMER_600US | (@as(u32, @intCast(reqLen)) << MESSAGE_SIZE_SHIFT));

    if (!mmio.waitUnset(CTL, SEND_BUSY, mmio.DefaultTimeoutMs)) {
        dbgCtl = mmio.rd(CTL); // timeout — still report what the ctl says
        return false;
    }
    const status = mmio.rd(CTL);
    dbgCtl = status;
    if ((status & (TIME_OUT_ERROR | RECEIVE_ERROR)) != 0) return false;

    const sizeField = (status & MESSAGE_SIZE_MASK) >> MESSAGE_SIZE_SHIFT;
    if (sizeField < 1) return false;
    respLen.* = @min(sizeField, 20);

    // unpack response
    i = 0;
    while (i < 5) : (i += 1) {
        const off = i * 4;
        if (off < respLen.*) {
            const count = @min(4, respLen.* - off);
            const v = mmio.rd(DATA[i]);
            var j: usize = 0;
            while (j < count) : (j += 1)
                resp[off + j] = @truncate(v >> @intCast((3 - j) * 8));
        }
    }
    dbgReply = resp[0];
    return true;
}

// Do_Aux_Request (dp_aux_request): up to 3 low-level tries.
fn doAuxRequestLow(req: *const AuxRequest, reqLen: usize, resp: *AuxResponse, respLen: *usize) bool {
    var ok = false;
    var t: u32 = 0;
    while (t < 3) : (t += 1) {
        ok = auxRequestLow(req, reqLen, resp, respLen);
        if (ok) break;
    }
    return ok;
}

// Do_Aux_Request (dp_aux_ch): retry on AUX defer, up to 32 tries.
fn doAuxRequest(req: *const AuxRequest, reqLen: usize, resp: *AuxResponse, respLen: *usize) bool {
    resp.* = @splat(0);
    respLen.* = 0;
    var ok = false;
    var t: u32 = 0;
    while (t < 32) : (t += 1) {
        ok = doAuxRequestLow(req, reqLen, resp, respLen);
        if (!(ok and isAuxDefer(resp))) break;
        mmio.sleepUs(500);
    }
    return ok and isAuxAck(resp);
}

fn dbgXfer(comptime wr: bool, addr: u32, ok: bool) void {
    mmio.say("aux "); mmio.say(if (wr) @as([*:0]const u8, "W ") else @as([*:0]const u8, "R "));
    mmio.sayHex(addr); mmio.say(" ok="); mmio.say(mmio.yn(ok));
    mmio.say(" reply="); mmio.sayHex(dbgReply);
    mmio.say(" ctl="); mmio.sayHex(dbgCtl); mmio.say("\n");
}

pub fn auxRead(addr: u32, buf: []u8) bool {
    const len = buf.len;
    if (len == 0 or len > 16) return false;
    const req = fillAuxRequest(DP_AUX_NATIVE_READ, addr, len);
    var resp: AuxResponse = undefined;
    var respLen: usize = 0;
    const ok = doAuxRequest(&req, 4, &resp, &respLen);
    dbgXfer(false, addr, ok);
    if (!ok) return false;
    if (respLen <= 1) return false;
    const n = @min(respLen - 1, len);
    @memcpy(buf[0..n], resp[1 .. 1 + n]);
    return true;
}

pub fn auxWrite(addr: u32, data: []const u8) bool {
    const len = data.len;
    if (len == 0 or len > 16) return false;
    var req = fillAuxRequest(DP_AUX_NATIVE_WRITE, addr, len);
    @memcpy(req[4 .. 4 + len], data);
    var resp: AuxResponse = undefined;
    var respLen: usize = 0;
    const ok = doAuxRequest(&req, 4 + len, &resp, &respLen);
    dbgXfer(true, addr, ok);
    return ok;
}

// Link-status read used by training: DPCD 0x202, 6 bytes.
pub fn auxRead6(addr: u32, buf: *[6]u8) bool {
    return auxRead(addr, buf);
}
