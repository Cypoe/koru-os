// koru/native/xhci — XHCI USB host-controller driver.
//
// Ported from the PROVEN koru-desktop provider
// providers/usb-xhci/app/xhci.c (itself written against the xHCI 1.2
// spec; landed + verified on linuxu/QEMU). This is the real path —
// no degraded mode.
//
// Flow per controller: find -> caps -> HCRST -> DCBAAP/CONFIG ->
// command+event rings (link-TRB wrapped) -> ERST/ERDP in RUNTIME space
// (bar0+RTSOFF, interrupter-0 block at +0x20) -> USBCMD RS|INTE ->
// port scan/reset -> Enable Slot -> Address Device -> GET_DESCRIPTOR
// (Device) -> VID:PID per attached device.
//
// Key register/TRB facts (from the reference, spec-verified):
//   TRB ctl dword: type = bits[15:10] (6b), cycle = bit0, TC=bit1,
//     LINK=bit2, IOC=bit5, IDT=bit6, slot-id = bits[31:24] (cmd TRBs),
//     event-TRB slot = ctl[31:24], completion code = st[31:24].
//   Command ring needs doorbell(0,0) after each command.
//   Transfer rings doorbell(slot, ep_target).
//   ERDP release = next_dequeue_phys | EHB(bit3).
//   phys==VA: pmm frames are identity-mapped in this kernel.

const std = @import("std");
const pci = @import("pci");
const pmm = @import("pmm");
const hostmmio = @import("mmio"); // host page-table mapper
const im = @import("i915/mmio.zig"); // say/sayHex/sayDec
const net = @import("net");

fn stage(comptime msg: [*:0]const u8) void {
    im.say(msg); im.say("\n");
    net.mark(std.mem.sliceTo(msg, 0));
}
// say/hex/dec dual-write: im.say -> serial+framebuffer, net.mirror -> UDP
// wire (:47820). Real-T590 debugging happens over UDP, so every runtime
// diagnostic token MUST take the mirror path or it is invisible on the wire.
fn say(s: [*:0]const u8) void {
    im.say(s);
    net.mirror(std.mem.sliceTo(s, 0));
}
fn hex32(v: u32) void {
    var b: [11]u8 = undefined;
    b[0] = '0'; b[1] = 'x';
    var i: usize = 2;
    var k: usize = 8;
    while (k > 0) : (k -= 1) {
        const n = (v >> @intCast(4 * (k - 1))) & 0xF;
        b[i] = "0123456789abcdef"[@intCast(n)];
        i += 1;
    }
    b[10] = 0;
    say(@ptrCast(&b));
}
fn hex64(v: u64) void {
    var b: [19]u8 = undefined;
    b[0] = '0'; b[1] = 'x';
    var i: usize = 2;
    var k: usize = 16;
    while (k > 0) : (k -= 1) {
        const n = (v >> @intCast(4 * (k - 1))) & 0xF;
        b[i] = "0123456789abcdef"[@intCast(n)];
        i += 1;
    }
    b[18] = 0;
    say(@ptrCast(&b));
}
fn dec(v: u64) void {
    var t: [20]u8 = undefined;
    var k: usize = 20;
    var n = v;
    if (n == 0) { k -= 1; t[k] = '0'; }
    else { while (n != 0) : (n /= 10) { k -= 1; t[k] = '0' + @as(u8, @intCast(n % 10)); } }
    var z: [21]u8 = undefined;
    var j: usize = 0;
    while (k < 20) : (k += 1) { z[j] = t[k]; j += 1; }
    z[j] = 0;
    say(@ptrCast(&z));
}

// ---- capability regs (off 0 of BAR0) ----
// cap0 dword: CAPLENGTH = &0xff, HCIVERSION = (>>16)&0xffff
// hcs1 @+4: maxslots=&0xff, maxints=(>>8)&0x7ff, maxports=(>>24)&0xff
// hcs2 @+8: scratchpad bufs = (>>27)&0x1f
// dword @+0x14: DBOFF = &~3 ; @+0x18: RTSOFF = &~0x1f
const CAP_HCSPARAMS = 0x04;
const CAP_HCCPARAMS2 = 0x08;
const CAP_DBOFF = 0x14;
const CAP_RTSOFF = 0x18;

// ---- operational regs (off CAPLENGTH) ----
const OP_USBCMD = 0x00;
const OP_USBSTS = 0x04;
const OP_DNCTRL = 0x14;
const OP_CRCR = 0x18;    // 64-bit command ring control
const OP_DCBAAP = 0x30;  // 64-bit device context base array ptr
const OP_CONFIG = 0x38;  // USBCFG: MaxSlotsEnabled[7:0]
fn opPortSc(i: u32) u32 { return 0x400 + 0x10 * i; }
const USBCMD_RS = 1 << 0;
const USBCMD_HCRST = 1 << 1;
const USBCMD_INTE = 1 << 2;
const USBSTS_HCH = 1 << 0;
const USBSTS_CNR = 1 << 11;
// PORTSC bits
const PSC_CCS = 1 << 0;
const PSC_PED = 1 << 1;
const PSC_PR = 1 << 4;
const PSC_PP = 1 << 16; // port power — MUST stay set or device drops
fn pscSpeed(v: u32) u32 { return (v >> 10) & 0xF; }
const PSC_WRC: u32 = (1 << 8) | (1 << 9) | (1 << 16) | (1 << 17) | (1 << 18) |
    (1 << 19) | (1 << 20) | (1 << 21) | (1 << 22) | (1 << 23) | (1 << 24);

// ---- runtime regs (off RTSOFF); interrupter-0 block at +0x20 ----
const RT_IR0 = 0x20;
const IR_IMAN = 0x00;
const IR_IMOD = 0x04;
const IR_ERSTSZ = 0x08;
const IR_ERSTBA = 0x10;
const IR_ERDP = 0x18;
const IMAN_IE = 1 << 1;
const IMAN_IP = 1 << 0;
const ERDP_EHB: u64 = 1 << 3;

// ---- TRB control-dword helpers ----
const Trb = extern struct { p_lo: u32, p_hi: u32, st: u32, ctl: u32 };
const TCYC: u32 = 1 << 0;
const TTC: u32 = 1 << 1;   // toggle cycle (link TRBs)
const TLINK: u32 = 1 << 2;
const TIOC: u32 = 1 << 5;  // interrupt on completion
const TIDT: u32 = 1 << 6;  // immediate data (setup TRB)
fn ttype(v: u32) u32 { return (v & 0x3F) << 10; }
const T_CMD = 1;
const T_NORMAL: u32 = 1; // == T_CMD: normal TRB (cmd TRBs are normal TRBs)
const T_CPL = 33;   // command completion event
const T_PSC = 34;   // port status change event
const T_XFER = 32;  // transfer event
const T_SETUP = 2;
const T_DATA = 3;
const T_STATUS = 4;
const T_LINK = 6;
const T_ENSLOT = 9;
const T_ADDR = 11;
const T_CFGEP = 12; // Configure Endpoint Context
const T_EVAL = 13;  // Evaluate Context
const T_ISP: u32 = 1 << 2;  // interrupt-on-short-packet (normal TRBs; == TTC bit)
const T_DIR_IN: u32 = 1 << 16; // TRB dir=IN (data/status stages)

// ---- context structs (32-byte ctx entries, DMA'd) ----
const Ctx32 = extern struct { d: [8]u32 };
const InputCtx = extern struct { ctrl: Ctx32, slot: Ctx32, ep: [31]Ctx32 };
const DevCtx = extern struct { slot: Ctx32, ep: [31]Ctx32 };
fn sCtxEntries(v: u32) u32 { return v << 27; }
fn sCtxRhPort(v: u32) u32 { return v << 16; }
fn sCtxSpeed(v: u32) u32 { return v << 20; }
const EP_CTX_TYPE_CTRL: u32 = 4 << 3;
fn epCtxMps(v: u32) u32 { return (v & 0xFFFF) << 16; }
fn epCtxCerr(v: u32) u32 { return (v & 3) << 1; }

// ---- DMA rings -------------------------------------------------------------
const Ring = struct {
    trbs: [*]volatile Trb,
    n: usize,
    enq: usize,
    deq: usize,
    pcs: u32, // producer/consumer cycle state, starts 1
};

var opbase: u64 = 0;
var rtsbase: u64 = 0;
var dbbase: u64 = 0;
var maxPorts: u32 = 0;
var maxSlots: u32 = 0;
var scratchBufs: u32 = 0;

var cring: Ring = undefined;
var ering: Ring = undefined;
var dcbaa: [*]volatile u64 = undefined;
var dcbaaPhys: u64 = 0;

// ---- low-level accessors ----------------------------------------------------
fn rd32(b: u64, o: u32) u32 {
    const p: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(b + o)));
    return p[0];
}
fn wr32(b: u64, o: u32, v: u32) void {
    const p: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(b + o)));
    p[0] = v;
}
fn wr64(b: u64, o: u32, v: u64) void {
    const p: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(b + o)));
    p[0] = v;
}
fn opRd(o: u32) u32 { return rd32(opbase, o); }
fn opWr(o: u32, v: u32) void { wr32(opbase, o, v); }
fn physOf(p: anytype) u64 { return @intFromPtr(p); }

// zero a full page of u64s
fn zeroPage(phys: u64) void {
    const p: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(phys)));
    var k: usize = 0;
    while (k < 512) : (k += 1) p[k] = 0;
}

// alloc one page, zero it, return phys
fn allocPage() ?u64 {
    const p = pmm.allocContiguous(1, 1) orelse return null;
    zeroPage(p);
    return p;
}

// ---- rings ------------------------------------------------------------------
fn ringInit(r: *Ring, trbPhys: u64, n: usize) void {
    const t: [*]volatile Trb = @ptrFromInt(@as(usize, @intCast(trbPhys)));
    r.trbs = t;
    r.n = n;
    r.enq = 0;
    r.deq = 0;
    r.pcs = 1;
    // link TRB at end: point back to ring start, TC so consumer flips cycle
    const base = trbPhys & ~@as(u64, 0xF);
    t[n - 1].p_lo = @truncate(base);
    t[n - 1].p_hi = @truncate(base >> 32);
    t[n - 1].st = 0;
    t[n - 1].ctl = ttype(T_LINK) | TTC;
}

fn ringPush(r: *Ring, p: u64, st: u32, ctl: u32) void {
    const t = &r.trbs[r.enq];
    t.p_lo = @truncate(p);
    t.p_hi = @truncate(p >> 32);
    t.st = st;
    t.ctl = ctl | r.pcs;
    r.enq += 1;
    if (r.enq >= r.n - 1) {
        const lk = &r.trbs[r.n - 1];
        lk.ctl = ttype(T_LINK) | TTC | r.pcs;
        r.enq = 0;
        r.pcs ^= 1;
    }
}

fn doorbell(slot: u32, target: u32) void {
    wr32(dbbase, slot * 4, target);
}

// Poll the event ring for a completion TRB whose TRB-pointer matches `want`
// (0 = any CPL/XFER/PSC). Advances dequeue, releases ERDP=next|EHB.
fn eventWait(ev: *Ring, want: u64, ccOut: ?*u32, slotOut: ?*u32) i32 {
    var spins: usize = 50_000_000;
    while (spins > 0) : (spins -= 1) {
        const t = &ev.trbs[ev.deq];
        if ((t.ctl & 1) != ev.pcs) continue;
        const ptr = (@as(u64, t.p_hi) << 32) | t.p_lo;
        const ty = (t.ctl >> 10) & 0x3F;
        const cc = (t.st >> 24) & 0xFF;
        lastEvtPtr = ptr; lastEvtSt = t.st; lastEvtCtl = t.ctl; lastEvtTy = ty;
        if (evtTrace) {
            say("  evt ty="); hex32(ty); say(" cc="); hex32(cc);
            say(" slot="); hex32((t.ctl >> 24) & 0xFF);
            say(" ptr="); hex64(ptr); say("\n");
        }
        ev.deq += 1;
        if (ev.deq >= ev.n - 1) {
            ev.deq = 0;
            ev.pcs ^= 1;
        }
        const dp = physOf(&ev.trbs[ev.deq]);
        wr64(rtsbase, RT_IR0 + IR_ERDP, dp | ERDP_EHB);
        if (ty == T_CPL or ty == T_XFER or ty == T_PSC) {
            if (want == 0 or ptr == want) {
                if (ccOut) |o| o.* = cc;
                if (slotOut) |o| o.* = (t.ctl >> 24) & 0xFF;
                return @intCast(ty);
            }
        }
    }
    return -1;
}

// wait for a transfer (EP) completion event — returns its completion
// code, or -1 on timeout. Accepts ANY T_XFER event regardless of which
// stage TRB the HC points at (real HW differs from QEMU here).
fn eventWaitXfer() i32 {
    var spins: usize = 50_000_000;
    while (spins > 0) : (spins -= 1) {
        const t = &ering.trbs[ering.deq];
        if ((t.ctl & 1) != ering.pcs) continue;
        const ptr = (@as(u64, t.p_hi) << 32) | t.p_lo;
        const ty = (t.ctl >> 10) & 0x3F;
        const cc = (t.st >> 24) & 0xFF;
        lastEvtPtr = ptr; lastEvtSt = t.st; lastEvtCtl = t.ctl; lastEvtTy = ty;
        ering.deq += 1;
        if (ering.deq >= ering.n - 1) { ering.deq = 0; ering.pcs ^= 1; }
        const dp = physOf(&ering.trbs[ering.deq]);
        wr64(rtsbase, RT_IR0 + IR_ERDP, dp | ERDP_EHB);
        if (ty == T_XFER) { return @intCast(cc); }
        if (evtTrace) {
            say("  evt ty="); hex32(ty); say(" cc="); hex32(cc);
            say(" ptr="); hex64(ptr); say("\n");
        }
    }
    return -1;
}

// issue a command TRB, ring doorbell 0, wait for its completion.
// returns slot id from the event, or -1.
fn xcmd(p: u64, st: u32, ctl: u32) i32 {
    const tptr = physOf(&cring.trbs[cring.enq]);
    ringPush(&cring, p, st, ctl);
    doorbell(0, 0);
    var cc: u32 = 0;
    var sl: u32 = 0;
    const r = eventWait(&ering, tptr, &cc, &sl);
    if (r < 0) {
        say("xhci: cmd timeout type="); hex32((ctl >> 10) & 0x3F); say("\n");
        return -1;
    }
    if (cc != 1) {
        say("xhci: cmd type="); hex32((ctl >> 10) & 0x3F);
        say(" cc="); hex32(cc); say(" slot="); hex32(sl);
        say(" evtTy="); hex32(lastEvtTy); say(" evtPtr="); hex64(lastEvtPtr);
        say(" evtSt="); hex32(lastEvtSt); say(" evtCtl="); hex32(lastEvtCtl); say("\n");
        return -1;
    }
    return @intCast(sl);
}

// generic control transfer on ep0's ring — port of hid.c ctrl_xfer.
// setup (+optional data) +status TRBs, doorbell ep0, wait any T_XFER.
// bufPhys = DMA buf for the data stage (ignored when wlen==0).
// dirIn = data-stage direction. Returns completion code (1 = success)
// or -1 on timeout. hid.c field-for-field: TRT = wlen?(in?3:2):0,
// status dir = (!wlen || !in) ? IN : OUT.
fn ctrlXfer(bmrt: u64, breq: u64, wval: u64, widx: u64, wlen: u32, bufPhys: u64, dirIn: bool) i32 {
    const setup = bmrt | (breq << 8) | (wval << 16) | (widx << 32) |
        (@as(u64, wlen) << 48);
    const trt: u32 = if (wlen != 0) (if (dirIn) 3 else 2) else 0;
    const t0 = &ep0Ring.trbs[ep0Ring.enq];
    ep0Trb(t0, setup, 8, ttype(T_SETUP) | TIDT | (trt << 16));
    ep0Ring.enq += 1;
    if (wlen != 0) {
        const t1 = &ep0Ring.trbs[ep0Ring.enq];
        ep0Trb(t1, bufPhys, wlen,
            ttype(T_DATA) | (if (dirIn) T_DIR_IN else 0) | TIOC);
        ep0Ring.enq += 1;
    }
    const sdir: u32 = if (wlen == 0 or !dirIn) T_DIR_IN else 0;
    const t2 = &ep0Ring.trbs[ep0Ring.enq];
    ep0Trb(t2, 0, 0, ttype(T_STATUS) | TIOC | sdir);
    const stPtr = physOf(t2);
    ep0Ring.enq += 1;
    say("xhci: ctrl bmrt="); hex32(@intCast(bmrt)); say(" req="); hex32(@intCast(breq));
    say(" wval="); hex32(@intCast(wval)); say(" wlen="); hex32(wlen);
    say(" stPtr="); hex64(stPtr); say(" slot="); hex32(curSlot); say("\n");
    doorbell(curSlot, 1);
    // Each IOC'd TRB posts its own T_XFER event in ring order: data stage
    // then status stage (wlen==0 -> status only). hid.c matched the status
    // TRB ptr to land on the LAST event; real HW reports evtPtr on an
    // earlier stage TRB (commit 60300fc) so we can't match ptr — instead
    // consume exactly the events this transfer generated and take the
    // last cc (status stage = the transfer's real result). Consuming only
    // one leaves a stale event that corrupts the NEXT transfer's cc —
    // measured on QEMU: cfg-hdr read cc=0x0d (the prior fetch's short-
    // packet data event) instead of cc=1.
    const wantEv: usize = if (wlen != 0) 2 else 1;
    var cc: i32 = -1;
    var k: usize = 0;
    while (k < wantEv) : (k += 1) {
        cc = eventWaitXfer();
        if (cc < 0) break;
    }
    say("xhci: ctrl cc="); hex32(@intCast(cc)); say(" evtPtr="); hex64(lastEvtPtr); say("\n");
    return cc;
}

// write one ep0 transfer TRB with the ring's current cycle bit —
// enq/wrap stays with the caller (ep0 transfers are few per device).
fn ep0Trb(t: *volatile Trb, p: u64, st: u32, ctl: u32) void {
    t.p_lo = @truncate(p);
    t.p_hi = @truncate(p >> 32);
    t.st = st;
    t.ctl = ctl | ep0Ring.pcs;
}

fn ep0GetDescG(wval: u64, widx: u64, bufPhys: u64, len: u32) i32 {
    return ctrlXfer(0x80, 6, wval, widx, len, bufPhys, true);
}

fn ep0GetDesc(bufPhys: u64) i32 { return ep0GetDescG(0x0100, 0, bufPhys, 18); }

var ep0Ring: Ring = undefined;
var ep0RingPhys: u64 = 0;
var curSlot: u32 = 0;
// last consumed event TRB — captured for failure diagnostics
var lastEvtPtr: u64 = 0;
var lastEvtSt: u32 = 0;
var lastEvtCtl: u32 = 0;
var lastEvtTy: u32 = 0;
var evtTrace: bool = false;

// real probe — takes the pci.Device
fn probeDev(d: *const pci.Device) u32 {
    var found: u32 = 0;
    const bar0 = pci.barPhys(d, 0);
    if (bar0 == 0) {
        stage("xhci: FAIL BAR0 unmapped");
        return 0;
    }
    pci.setCommand(d, pci.command(d) | 0x6); // mem space + bus master
    if (!hostmmio.map(bar0, 0x10000)) {
        stage("xhci: FAIL BAR0 map");
        return 0;
    }
    const cap0 = rd32(bar0, 0);
    const caplen: u64 = cap0 & 0xFF;
    const hcs1 = rd32(bar0, CAP_HCSPARAMS);
    const hcs2 = rd32(bar0, CAP_HCCPARAMS2);
    const dboff = rd32(bar0, CAP_DBOFF) & ~@as(u32, 3);
    const rtsoff = rd32(bar0, CAP_RTSOFF) & ~@as(u32, 0x1F);
    opbase = bar0 + caplen;
    rtsbase = bar0 + rtsoff;
    dbbase = bar0 + dboff;
    maxSlots = hcs1 & 0xFF;
    maxPorts = (hcs1 >> 24) & 0xFF;
    scratchBufs = (hcs2 >> 27) & 0x1F;
    const hcver = (cap0 >> 16) & 0xFFFF;
    say("xhci: ctrl "); dec(d.bus); say(":"); dec(d.slot); say("."); dec(d.func);
    say(" hci v"); hex32(hcver >> 8); say("."); hex32(hcver & 0xFF);
    say(" slots="); dec(maxSlots); say(" ints="); dec((hcs1 >> 8) & 0x7FF);
    say(" ports="); dec(maxPorts); say(" scratch="); dec(scratchBufs);
    say(" caplen="); dec(caplen); say(" dboff="); hex32(dboff);
    say(" rtsoff="); hex32(rtsoff); say("\n");
    stage("xhci: caps read");

    // ---- reset ----
    opWr(OP_USBCMD, opRd(OP_USBCMD) | USBCMD_HCRST);
    var i: u32 = 0;
    while (i < 100000 and (opRd(OP_USBCMD) & USBCMD_HCRST) != 0) : (i += 1) {}
    i = 0;
    while (i < 100000 and (opRd(OP_USBSTS) & USBSTS_CNR) != 0) : (i += 1) {}
    say("xhci: reset done sts="); hex32(opRd(OP_USBSTS)); say("\n");
    stage("xhci: HC reset");

    // ---- DCBAA + CONFIG ----
    const dcbaaPage = allocPage() orelse {
        stage("xhci: FAIL dcbaa alloc"); return 0;
    };
    dcbaaPhys = dcbaaPage;
    dcbaa = @ptrFromInt(@as(usize, @intCast(dcbaaPhys)));
    // CONFIG.MaxSlotsEnabled — enable up to 8 slots (enough for HID pair)
    const cfgSlots: u32 = if (maxSlots < 8) maxSlots else 8;
    opWr(OP_CONFIG, cfgSlots);

    // scratchpad buffers if the HC requires them (Intel does)
    if (scratchBufs > 0) {
        const arrPhys = allocPage() orelse {
            stage("xhci: FAIL scratch array alloc"); return 0;
        };
        const arr: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(arrPhys)));
        var k: u32 = 0;
        while (k < scratchBufs) : (k += 1) {
            const bp = allocPage() orelse {
                stage("xhci: FAIL scratch buf alloc"); return 0;
            };
            arr[k] = bp;
        }
        dcbaa[0] = arrPhys;
        say("xhci: scratchpad array="); dec(arrPhys); say(" n="); dec(scratchBufs); say("\n");
    }
    wr64(opbase, OP_DCBAAP, dcbaaPhys);
    stage("xhci: DCBAAP+CONFIG set");

    // ---- command + event rings ----
    const cmdPhys = allocPage() orelse {
        stage("xhci: FAIL cmdring alloc"); return 0;
    };
    const evtPhys = allocPage() orelse {
        stage("xhci: FAIL evtring alloc"); return 0;
    };
    const erstPhys = allocPage() orelse {
        stage("xhci: FAIL erst alloc"); return 0;
    };
    ringInit(&cring, cmdPhys, 64);
    ringInit(&ering, evtPhys, 64);
    // ERST: one segment -> evt ring, size = usable TRBs (n-1, link at end)
    {
        const e: [*]volatile Trb = @ptrFromInt(@as(usize, @intCast(erstPhys)));
        e[0].p_lo = @truncate(evtPhys & ~@as(u64, 0xF));
        e[0].p_hi = @truncate((evtPhys & ~@as(u64, 0xF)) >> 32);
        e[0].st = @intCast(ering.n - 1); // segment size in TRBs
        e[0].ctl = 0;
        wr32(rtsbase, RT_IR0 + IR_ERSTSZ, 1);
        wr64(rtsbase, RT_IR0 + IR_ERSTBA, erstPhys);
        wr64(rtsbase, RT_IR0 + IR_ERDP, evtPhys & ~@as(u64, 0xF));
    }
    // ack stale interrupt-pending, enable interrupter
    wr32(rtsbase, RT_IR0 + IR_IMAN, rd32(rtsbase, RT_IR0 + IR_IMAN) | IMAN_IP | IMAN_IE);
    // command ring: CRCR = base | RCS(bit0). CS is HC-managed.
    wr64(opbase, OP_CRCR, (cmdPhys & ~@as(u64, 0x3F)) | 1);
    opWr(OP_USBCMD, opRd(OP_USBCMD) | USBCMD_RS); // no INTE: we poll; IRQ on unhandled vec panics
    i = 0;
    while (i < 100000 and (opRd(OP_USBSTS) & USBSTS_HCH) != 0) : (i += 1) {}
    say("xhci: running sts="); hex32(opRd(OP_USBSTS)); say("\n");
    say("xhci: cmdring="); dec(cmdPhys); say(" evtring="); dec(evtPhys); say("\n");
    stage("xhci: rings armed, HC running");

    // ---- port scan + per-device enumeration ----
    var port: u32 = 0;
    while (port < maxPorts) : (port += 1) {
        var ps = opRd(opPortSc(port));
        const ccs = (ps & PSC_CCS) != 0;
        say("xhci: port"); dec(port); say(" sc="); hex32(ps);
        say(" ccs="); if (ccs) say("1") else say("0");
        say(" speed="); hex32(pscSpeed(ps)); say("\n");
        if (!ccs) continue;

        // port reset — write ps|PR|PP: preserves PP (bit16) so the port
        // stays powered, preserves RW state, acks pending change bits.
        // The reference's (ps & ~PSC_WRC) clears bit16=PP -> port powers
        // off -> device disconnects on real silicon (QEMU tolerates it).
        opWr(opPortSc(port), ps | PSC_PR | PSC_PP);
        i = 0;
        while (i < 1000000) : (i += 1) {
            ps = opRd(opPortSc(port));
            if ((ps & PSC_PR) == 0) break;
        }
        // drain port-status-change events
        while (eventWait(&ering, 0, null, null) == T_PSC) {}
        // wait for link retrain: CCS+PED+speed!=0. Reading speed right
        // after PR-clear yields 0 on real HW (USB2 training is slow) ->
        // slot-ctx speed=0 -> SET_ADDRESS transaction error.
        var ready: u32 = 0;
        i = 0;
        while (i < 5000000) : (i += 1) {
            ps = opRd(opPortSc(port));
            if ((ps & PSC_CCS) != 0 and (ps & PSC_PED) != 0 and pscSpeed(ps) != 0) {
                ready = ps;
                break;
            }
        }
        if (ready != 0) ps = ready;
        const speed = pscSpeed(ps);
        const pls = (ps >> 5) & 0xF; // port link state for decode
        say("xhci: port"); dec(port); say(" post-reset sc="); hex32(ps);
        say(" ccs="); if ((ps & PSC_CCS) != 0) say("1") else say("0");
        say(" ped="); if ((ps & PSC_PED) != 0) say("1") else say("0");
        say(" pls="); hex32(pls); say(" speed="); hex32(speed); say("\n");

        // ---- Enable Slot ----
        const slotId = xcmd(0, 0, ttype(T_ENSLOT));
        if (slotId <= 0) {
            say("xhci: port"); dec(port); say(" enable-slot FAIL\n");
            stage("xhci: FAIL enable slot");
            continue;
        }
        curSlot = @intCast(slotId);
        say("xhci: port"); dec(port); say(" slot="); dec(@as(u64, @intCast(slotId))); say("\n");
        stage("xhci: slot allocated");

        // ---- input context: add slot-ctx + ep0-ctx ----
        const icPhys = allocPage() orelse {
            stage("xhci: FAIL inputctx alloc"); return found;
        };
        const ic: *InputCtx = @ptrFromInt(@as(usize, @intCast(icPhys)));
        ic.ctrl.d[0] = 0;      // drop flags
        ic.ctrl.d[1] = 0x3;    // add flags: slot ctx (bit0) + ep0 ctx (bit1)
        ic.slot.d[0] = sCtxEntries(1) | sCtxSpeed(speed);
        ic.slot.d[1] = sCtxRhPort(port + 1); // 1-based root-hub port
        const ep0Phys = allocPage() orelse {
            stage("xhci: FAIL ep0ring alloc"); return found;
        };
        ringInit(&ep0Ring, ep0Phys, 32);
        ep0RingPhys = ep0Phys;
        // control EP: type=ctrl, cerr=3, mps by speed (SS=512, HS=64, else 8)
        const mps: u32 = if (speed == 4) 512 else if (speed == 3) 64 else 8;
        ic.ep[0].d[0] = 0;
        ic.ep[0].d[1] = EP_CTX_TYPE_CTRL | epCtxCerr(3) | epCtxMps(mps);
        ic.ep[0].d[2] = @truncate(ep0Phys | 1); // dequeue ptr | DCS=1
        ic.ep[0].d[3] = @truncate(ep0Phys >> 32);
        ic.ep[0].d[4] = 8; // avg TRB len
        // device context (output) -> dcbaa[slot]
        const dcPhys = allocPage() orelse {
            stage("xhci: FAIL devctx alloc"); return found;
        };
        dcbaa[@intCast(slotId)] = dcPhys;

        // dump the input context + ep0 ring base so a malformed ctx is
        // visible on the wire; trace events during the command.
        say("xhci: addrdev port="); dec(port); say(" slot="); dec(@as(u64,@intCast(slotId))); say("\n");
        say("xhci: ic ctrl d0/d1="); hex32(ic.ctrl.d[0]); say("/"); hex32(ic.ctrl.d[1]);
        say(" slot d0="); hex32(ic.slot.d[0]); say(" d1="); hex32(ic.slot.d[1]);
        say(" ep0 d1="); hex32(ic.ep[0].d[1]); say(" d2="); hex32(ic.ep[0].d[2]);
        say(" d4="); hex32(ic.ep[0].d[4]); say(" speed="); hex32(speed);
        say(" mps="); hex32(mps); say(" icPhys="); hex64(icPhys); say("\n");
        evtTrace = true;
        const addrRc = xcmd(icPhys, 0, ttype(T_ADDR) | (@as(u32, @intCast(slotId)) << 24));
        evtTrace = false;
        if (addrRc < 0) {
            const us = opRd(OP_USBSTS);
            const ps2 = opRd(opPortSc(port));
            say("xhci: addr FAIL usbsts="); hex32(us);
            say(" csec="); if ((us & (1 << 18)) != 0) say("1") else say("0");
            say(" portsc="); hex32(ps2);
            say(" ccs="); if ((ps2 & PSC_CCS) != 0) say("1") else say("0");
            say(" ped="); if ((ps2 & PSC_PED) != 0) say("1") else say("0");
            say(" pr="); if ((ps2 & PSC_PR) != 0) say("1") else say("0"); say("\n");
            // did the HC write anything into the device context?
            const dcp: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(dcPhys)));
            say("xhci: devctx[0..3]="); hex64(dcp[0]); say(" "); hex64(dcp[1]); say("\n");
            stage("xhci: FAIL address device");
            continue;
        }
        say("xhci: port"); dec(port); say(" addressed slot="); dec(@as(u64, @intCast(slotId))); say("\n");
        stage("xhci: device addressed");

        // ---- GET_DESCRIPTOR(Device) ----
        const bufPhys = allocPage() orelse {
            stage("xhci: FAIL descbuf alloc"); return found;
        };
        const buf: [*]u8 = @ptrFromInt(@as(usize, @intCast(bufPhys)));
        const cc = ep0GetDesc(bufPhys);
        if (cc != 1) {
            say("xhci: port"); dec(port); say(" getdesc cc="); hex32(@intCast(cc)); say("\n");
            stage("xhci: FAIL get descriptor");
            continue;
        }
        const vid = @as(u32, buf[8]) | (@as(u32, buf[9]) << 8);
        const pid = @as(u32, buf[10]) | (@as(u32, buf[11]) << 8);
        say("xhci: DEV port="); dec(port); say(" vid="); hex32(vid);
        say(" pid="); hex32(pid); say(" len="); hex32(buf[0]); say("\n");
        stage("xhci: device identified");
        found += 1;
        enumHid(port, slotId);
    }
    if (found == 0) {
        stage("xhci: no devices enumerated");
    } else {
        say("xhci: enumerated "); dec(found); say(" device(s)\n");
        stage("xhci: ==== ENUM DONE ====");
    }
    return found;
}

// ---- STAGE A: HID descriptor enumeration ----------------------------------
fn enumHid(port: u32, slotId: i32) void {
    _ = port;
    // config descriptor (type 2) up to 255 bytes into a scratch page
    const cfgPhys = allocPage() orelse return;
    const cc = ep0GetDescG(0x0200, 0, cfgPhys, 255);
    if (cc != 1) { say("xhci: cfgdesc cc="); hex32(@intCast(cc)); say("\n"); return; }
    const cfg: [*]u8 = @ptrFromInt(@as(usize, @intCast(cfgPhys)));
    const total = @as(usize, cfg[2]) | (@as(usize, cfg[3]) << 8);
    say("xhci: cfg total="); hex32(@intCast(total)); say("\n");
    var pos: usize = cfg[0]; // skip config header (9 bytes)
    while (pos + 2 <= total and pos + 2 <= 255) {
        const bl = cfg[pos];
        const bt = cfg[pos + 1];
        if (bl < 2) break;
        if (bt == 4) { // interface
            say("xhci: IF num="); hex32(cfg[pos+2]);
            say(" alt="); hex32(cfg[pos+3]);
            say(" nep="); hex32(cfg[pos+4]);
            say(" class="); hex32(cfg[pos+5]);
            say(" sub="); hex32(cfg[pos+6]);
            say(" proto="); hex32(cfg[pos+7]); say("\n");
        } else if (bt == 5) { // endpoint
            say("xhci: EP addr="); hex32(cfg[pos+2]);
            say(" attr="); hex32(cfg[pos+3]);
            say(" mps="); hex32(@as(u32,cfg[pos+4]) | (@as(u32,cfg[pos+5])<<8));
            say(" ivl="); hex32(cfg[pos+6]); say("\n");
        } else if (bt == 0x21) { // HID
            say("xhci: HID ver="); hex32(@as(u32,cfg[pos+2])|(@as(u32,cfg[pos+3])<<8));
            say(" ndesc="); hex32(cfg[pos+5]);
            // report descriptor length at +7/+8 if present
            say(" rdlen="); hex32(@as(u32,cfg[pos+7])|(@as(u32,cfg[pos+8])<<8)); say("\n");
        }
        pos += bl;
    }
    stage("xhci: config parsed");
    hidStageB(slotId);
}

// ---- STAGE B: interrupt-IN HID reports ------------------------------------
// Port of koru-desktop providers/usb-hid/app/hid.c: parse_config ->
// ConfigureEP (interrupt-IN endpoint ctx via Configure Endpoint Context
// command) -> SET_CONFIGURATION -> interrupt transfer ring + report poll.
// Field-for-field vs hid.c; runtime values dual-write serial/fb + UDP.

const HidEp = struct {
    cfgVal: u32 = 1,
    iface: u32 = 0,
    proto: u32 = 0,
    addr: u32 = 0,
    mps: u32 = 0,
    ival: u32 = 0,
};

// scan config descriptor for the first HID interface (class 3) + its
// interrupt-IN endpoint — hid.c parse_config verbatim. cfgVal carries
// bConfigurationValue out of the config header (type 2) for
// SET_CONFIGURATION. cfg[0] must be the config header start.
fn parseConfig(cfg: [*]const u8, len: usize, e: *HidEp) bool {
    var i: usize = 0;
    var foundIf = false;
    while (i + 2 <= len) {
        const blen = cfg[i];
        const btype = cfg[i + 1];
        if (blen < 2) break;
        if (btype == 4 and blen >= 9 and cfg[i + 5] == 3) { // HID iface
            e.iface = cfg[i + 2];
            e.proto = cfg[i + 7];
            foundIf = true;
        } else if (btype == 5 and foundIf and blen >= 7) { // endpoint
            const attr = cfg[i + 3] & 3;
            if ((cfg[i + 2] & 0x80) != 0 and attr == 3) { // IN + interrupt
                e.addr = cfg[i + 2];
                e.mps = @as(u32, cfg[i + 4]) | (@as(u32, cfg[i + 5]) << 8);
                e.ival = cfg[i + 6];
                return true;
            }
        } else if (btype == 2 and blen >= 9) { // config header
            e.cfgVal = cfg[i + 5]; // bConfigurationValue
        }
        i += blen;
    }
    return false;
}

fn hidStageB(slotId: i32) void {
    say("xhci: stageB slot="); hex32(@intCast(slotId)); say("\n");
    // config descriptor — header (9B) then full body, hid.c sequence.
    const cfgPhys = allocPage() orelse return;
    const cc0 = ctrlXfer(0x80, 6, 0x0200, 0, 9, cfgPhys, true);
    if (cc0 != 1) {
        say("xhci: hid cfg-hdr cc="); hex32(@intCast(cc0)); say("\n");
        return;
    }
    const cfg: [*]u8 = @ptrFromInt(@as(usize, @intCast(cfgPhys)));
    var total = @as(usize, cfg[2]) | (@as(usize, cfg[3]) << 8);
    if (total > 4000) total = 4000; // one page of DMA buf
    const cc1 = ctrlXfer(0x80, 6, 0x0200, 0, @intCast(total), cfgPhys, true);
    if (cc1 != 1) {
        say("xhci: hid cfg cc="); hex32(@intCast(cc1)); say("\n");
        return;
    }
    say("xhci: hid cfg total="); hex32(@intCast(total)); say("\n");

    var e: HidEp = .{};
    if (!parseConfig(cfg, total, &e)) {
        say("xhci: no HID int-in ep — skip\n");
        return;
    }
    say("xhci: hid iface="); hex32(e.iface); say(" proto="); hex32(e.proto);
    say(" ep=0x"); hex32(e.addr); say(" mps="); hex32(e.mps);
    say(" ival="); hex32(e.ival); say(" cfg="); hex32(e.cfgVal); say("\n");
    stage("xhci: hid endpoint found");

    // DCI for interrupt-IN endpoint: epn*2 + 1 (hid.c)
    const epn = e.addr & 0xF;
    const dci = epn * 2 + 1;
    say("xhci: dci="); hex32(dci); say("\n");

    // ConfigureEP input context (hid.c): fresh zeroed ctx, add flags =
    // slot ctx (bit0) + endpoint ctx for this dci; slot ctx carries only
    // Context Entries = dci.
    const icPhys = allocPage() orelse return;
    const ic: *InputCtx = @ptrFromInt(@as(usize, @intCast(icPhys)));
    ic.ctrl.d[1] = 1 | (@as(u32, 1) << @as(u5, @intCast(dci)));
    ic.slot.d[0] = dci << 27;
    // interrupt-IN transfer ring (32 TRBs) + report buffer
    const intPhys = allocPage() orelse return;
    var intRing: Ring = undefined;
    ringInit(&intRing, intPhys, 32);
    const repPhys = allocPage() orelse return;
    const repbuf: [*]u8 = @ptrFromInt(@as(usize, @intCast(repPhys)));
    @memset(repbuf[0..64], 0);

    // endpoint ctx d[0..4] — hid.c verbatim: interval@d0[23:16],
    // type=7 (intr-IN)@d1[5:3], cerr=3@d1[2:1], mps@d1[31:16],
    // dequeue|DCS@d2/d3, avg-trb-len=8@d4.
    var cival = e.ival;
    if (cival < 1) cival = 1;
    if (cival > 16) cival = 16;
    const ectx = &ic.ep[@intCast(dci - 1)];
    ectx.d[0] = cival << 16;
    ectx.d[1] = (7 << 3) | (3 << 1) | ((e.mps & 0x7FF) << 16);
    ectx.d[2] = @truncate(intPhys | 1); // dequeue ptr | DCS=1
    ectx.d[3] = @truncate(intPhys >> 32);
    ectx.d[4] = 8;
    say("xhci: cfgEP ic ctrl d1="); hex32(ic.ctrl.d[1]);
    say(" slot d0="); hex32(ic.slot.d[0]);
    say(" ep d0="); hex32(ectx.d[0]); say(" d1="); hex32(ectx.d[1]);
    say(" d2="); hex32(ectx.d[2]); say(" d4="); hex32(ectx.d[4]); say("\n");
    const rc = xcmd(icPhys, 0, ttype(T_CFGEP) | (@as(u32, @intCast(slotId)) << 24));
    say("xhci: configure-ep dci="); hex32(dci); say(" rc="); hex32(@intCast(rc)); say("\n");
    if (rc < 0) {
        stage("xhci: FAIL configure endpoint");
        return;
    }
    stage("xhci: endpoint configured");

    // SET_CONFIGURATION — hid.c: bmRT=0 req=9 wVal=cfgVal, no data stage
    const scc = ctrlXfer(0x00, 9, e.cfgVal, 0, 0, 0, false);
    say("xhci: set-config "); hex32(e.cfgVal); say(" cc="); hex32(@intCast(scc)); say("\n");
    if (scc != 1) {
        stage("xhci: FAIL set configuration");
        return;
    }
    stage("xhci: configured — polling interrupt-IN");

    // interrupt report loop — hid.c post_report_trb + doorbell(slot,dci)
    // + event wait per poll. Each completion hex-dumps the report bytes;
    // one say() = one UDP datagram on :47820.
    var reports: usize = 0;
    var polls: usize = 0;
    while (polls < 96 and reports < 32) : (polls += 1) {
        ringPush(&intRing, repPhys, 8, ttype(T_NORMAL) | TIOC | T_ISP);
        doorbell(@intCast(slotId), @intCast(dci));
        @memset(repbuf[0..16], 0);
        const cc = eventWaitXfer();
        if (cc < 0) continue;
        const xlen = lastEvtSt & 0x1FFFF; // transfer event: bytes moved
        var b: [224]u8 = undefined;
        const s = std.fmt.bufPrintZ(&b,
            "xhci: RPT slot={d} cc={x} len={d} st={x} b={x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}\n",
            .{ slotId, cc, xlen, lastEvtSt,
              repbuf[0], repbuf[1], repbuf[2], repbuf[3],
              repbuf[4], repbuf[5], repbuf[6], repbuf[7] }) catch return;
        say(s.ptr);
        reports += 1;
    }
    say("xhci: report-poll done reports="); dec(reports); say("\n");
    stage("xhci: hid reports done");
}

// ---- entry: probe every XHCI controller -------------------------------------
pub fn init() bool {
    stage("xhci: ==== XHCI ENUM ====");
    pci.init();
    var any = false;
    var i: usize = 0;
    while (i < pci.count) : (i += 1) {
        const d = &pci.devices[i];
        if (d.class == 0x0C and d.subclass == 0x03 and d.progif == 0x30) {
            if (probeDev(d) > 0) any = true;
        }
    }
    if (!any) stage("xhci: no XHCI devices answered");
    return any;
}
