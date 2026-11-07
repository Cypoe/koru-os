// koru/native i915/pcode — GT mailbox, ported from
// libgfxinit common/hw-gfx-gma-pcode.adb (coreboot, GPL-2.0).
//
// The pcode mailbox talks to the PCH-side microcontroller that owns
// CDCLK/pll sequencing on SKL+. Commands are 64-bit: write lo/hi dwords
// to GT_MAILBOX_DATA[_1], then GT_MAILBOX = READY|mbox; the ack clears
// READY and the reply lands in the data regs.

const mmio = @import("mmio.zig");
const R = mmio.R;

const GT_MAILBOX_READY: u32 = 1 << 31;
const GT_MAILBOX: u32 = R.GT_MAILBOX;
const GT_MAILBOX_DATA: u32 = R.GT_MAILBOX_DATA;
const GT_MAILBOX_DATA_1: u32 = R.GT_MAILBOX_DATA_1;

var mailboxReady: bool = false;

// Mailbox_Write_Read: send Command on MBox, optionally wait for the
// mailbox to be free first (Wait_Ready) and/or for the ack (Wait_Ack).
// On ack, Reply holds the 64-bit response.
pub fn mailboxWriteRead(
    mbox: u32,
    command: u64,
    waitReady: bool,
    waitAck: bool,
) struct { ok: bool, reply: u64 } {
    var reply: u64 = 0;
    if (waitReady) {
        if (!mmio.waitUnset(GT_MAILBOX, GT_MAILBOX_READY, mmio.DefaultTimeoutMs))
            return .{ .ok = false, .reply = 0 };
    }
    mmio.wr(GT_MAILBOX_DATA, @truncate(command));
    mmio.wr(GT_MAILBOX_DATA_1, @truncate(command >> 32));
    mmio.wr(GT_MAILBOX, GT_MAILBOX_READY | mbox);
    mailboxReady = false;
    if (!waitAck) return .{ .ok = true, .reply = 0 };

    const ok = mmio.waitUnset(GT_MAILBOX, GT_MAILBOX_READY, mmio.DefaultTimeoutMs);
    mailboxReady = ok;
    if (!ok) return .{ .ok = false, .reply = 0 };

    const lo = mmio.rd(GT_MAILBOX_DATA);
    const hi = mmio.rd(GT_MAILBOX_DATA_1);
    reply = (@as(u64, hi) << 32) | lo;
    mmio.wr(GT_MAILBOX_DATA, 0);
    mmio.wr(GT_MAILBOX_DATA_1, 0);
    return .{ .ok = true, .reply = reply };
}

pub fn mailboxWrite(mbox: u32, command: u64, waitReady: bool) bool {
    return mailboxWriteRead(mbox, command, waitReady, true).ok;
}

// Mailbox_Request: send Command repeatedly until the reply matches
// Reply under Reply_Mask (default: any reply), bounded by timeoutMs.
pub fn mailboxRequest(
    mbox: u32,
    command: u64,
    replyMask: u64,
    replyWant: u64,
    timeoutMs: u32,
    waitReady: bool,
) bool {
    const deadline = nowMs() + timeoutMs;
    var ok = false;
    while (true) {
        const r = mailboxWriteRead(mbox, command, !ok and waitReady, true);
        ok = r.ok;
        if (!ok) return false;
        if ((r.reply & replyMask) == (replyWant & replyMask)) return true;
        if (nowMs() >= deadline) return false;
    }
}

fn nowMs() u64 {
    return mmio.nowMs();
}
