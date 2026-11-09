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
fn say(s: [*:0]const u8) void { im.say(s); }
fn hex32(v: u32) void { im.sayHex(v); }
fn hex64(v: u64) void {
    im.sayHex(@intCast(v >> 32)); im.sayHex(@intCast(v & 0xFFFFFFFF));
}
fn dec(v: u64) void { im.sayDec(v); }

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
const T_CPL = 33;   // command completion event
const T_PSC = 34;   // port status change event
const T_XFER = 32;  // transfer event
const T_SETUP = 2;
const T_DATA = 3;
const T_STATUS = 4;
const T_LINK = 6;
const T_ENSLOT = 9;
const T_ADDR = 11;

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

// GET_DESCRIPTOR(Device) on ep0's transfer ring. bufPhys = DMA buf (18B).
// returns completion code (1 = success) or -1.
fn ep0GetDesc(bufPhys: u64) i32 {
    var setup: u64 = 0;
    // bmRT=0x80, bReq=6 GET_DESCRIPTOR, wValue=0x0100 (device), wIndex=0,
    // wLength=18.
    setup = @as(u64, 0x80) | (@as(u64, 6) << 8) |
        (@as(u64, 0x0100) << 16) | (@as(u64, 18) << 48);
    const t0 = &ep0Ring.trbs[ep0Ring.enq];
    t0.p_lo = @truncate(setup);
    t0.p_hi = @truncate(setup >> 32);
    t0.st = 8;
    t0.ctl = ttype(T_SETUP) | TIDT | (3 << 16) | ep0Ring.pcs; // TRT=3 in-data
    ep0Ring.enq += 1;
    const t1 = &ep0Ring.trbs[ep0Ring.enq];
    t1.p_lo = @truncate(bufPhys);
    t1.p_hi = @truncate(bufPhys >> 32);
    t1.st = 18;
    t1.ctl = ttype(T_DATA) | (1 << 16) | TIOC | ep0Ring.pcs; // DIR=in
    ep0Ring.enq += 1;
    const t2 = &ep0Ring.trbs[ep0Ring.enq];
    t2.p_lo = 0;
    t2.p_hi = 0;
    t2.st = 0;
    t2.ctl = ttype(T_STATUS) | TIOC | ep0Ring.pcs;
    const stPtr = physOf(t2);
    ep0Ring.enq += 1;
    doorbell(curSlot, 1);
    var cc: u32 = 0;
    var sl: u32 = 0;
    const r = eventWait(&ering, stPtr, &cc, &sl);
    return if (r < 0) -1 else @intCast(cc);
}

var ep0Ring: Ring = undefined;
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
    opWr(OP_USBCMD, opRd(OP_USBCMD) | USBCMD_RS | USBCMD_INTE);
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

        // port reset (USB2 needs it; USB3 auto) — preserve CCS, set PR
        opWr(opPortSc(port), (ps & ~PSC_WRC) | PSC_PR | (ps & PSC_CCS));
        i = 0;
        while (i < 1000000) : (i += 1) {
            ps = opRd(opPortSc(port));
            if ((ps & PSC_PR) == 0) break;
        }
        // drain port-status-change events
        while (eventWait(&ering, 0, null, null) == T_PSC) {}
        ps = opRd(opPortSc(port));
        const speed = pscSpeed(ps);
        say("xhci: port"); dec(port); say(" post-reset sc="); hex32(ps);
        say(" ped="); if ((ps & PSC_PED) != 0) say("1") else say("0");
        say(" speed="); hex32(speed); say("\n");

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
            say("xhci: addr FAIL usbsts="); hex32(us);
            say(" csec="); if ((us & (1 << 18)) != 0) say("1") else say("0"); say("\n");
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
    }
    if (found == 0) {
        stage("xhci: no devices enumerated");
    } else {
        say("xhci: enumerated "); dec(found); say(" device(s)\n");
        stage("xhci: ==== ENUM DONE ====");
    }
    return found;
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
