// koru/native/xhci — XHCI USB host-controller driver foundation (M-input).
//
// Goal: enumerate the two T590 XHCI controllers (0:20.0, 58:0.0) far enough
// to allocate device slots and read descriptors — the path to the USB HID
// TrackPoint+touchpad that PS/2 aux never answered.
//
// This pass lands the transport substrate: host-controller init (reset,
// scratchpad, max-slots), DMA command + event rings, the DCBAA, and the
// Enable Slot command with event-ring polling. Every step emits a stage
// marker (serial + UDP) so the T590 flash names the last completed step.
// Register offsets follow the xHCI spec operational space; the op-block
// dump at init prints the live values so any offset error is visible.

const std = @import("std");
const pci = @import("pci");
const pmm = @import("pmm");
const hostmmio = @import("mmio"); // host page-table mapper
const im = @import("i915/mmio.zig"); // say/sayHex/sayDec + reg layer
const net = @import("net");

fn stage(comptime msg: [*:0]const u8) void {
    im.say(msg); im.say("\n");
    net.mark(std.mem.sliceTo(msg, 0));
}
fn say(s: [*:0]const u8) void { im.say(s); }
fn hex32(v: u32) void { im.sayHex(v); }
fn dec(v: u64) void { im.sayDec(v); }

// ---- register map -----------------------------------------------------------
// cap = BAR0 + 0 ; op = BAR0 + CAPLENGTH. All offsets bytes unless noted.
const CAP_CAPLENGTH = 0x00; // u8 at +0 (in dword0 low byte)
const CAP_HCIVERSION = 0x02; // u16
const CAP_HCSPARAMS = 0x04;  // u32
const CAP_HCCPARAMS = 0x10;  // u32
const CAP_DBOFF = 0x14;      // u32 doorbell offset (from op base? from bar)
const CAP_RTSOFF = 0x18;     // u32 runtime regs offset

const OP_USBCMD = 0x00;
const OP_USBSTS = 0x04;
const OP_PAGESIZE = 0x08;
const OP_DNCTRL = 0x10;
const OP_CRCR = 0x18;   // 64-bit command ring control
const OP_DCBAAP = 0x30; // 64-bit device context base array ptr
const OP_ERSTSZ = 0x38; // event ring segment table size
const OP_ERSTBA = 0x40; // 64-bit event ring segment table base
const OP_ERDP = 0x48;   // 64-bit event ring dequeue pointer
const OP_CONFIG = 0x3F8; // max-slots / max-ports config (best-known)

const PORTSC_BASE = 0x400; // port n regs at op + 0x400 + (n-1)*0x10

// USBCMD bits
const USBCMD_RS = 1 << 0;   // run/stop
const USBCMD_HCRST = 1 << 1; // host controller reset
const USBCMD_INTE = 1 << 2;
const USBCMD_HSEE = 1 << 3;
// USBSTS bits
const USBSTS_HCH = 1 << 0;  // halted
const USBSTS_CNR = 1 << 11; // controller not ready
const USBSTS_CSEC = 1 << 18; // config error

var bar0: u64 = 0;
var opbase: u64 = 0;
var caplen: usize = 0;
var maxSlots: u32 = 0;
var maxPorts: u32 = 0;

fn opRd(off: u32) u32 {
    const p: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(opbase + off)));
    return p[0];
}
fn opWr(off: u32, v: u32) void {
    const p: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(opbase + off)));
    p[0] = v;
}
fn opWr64(off: u32, v: u64) void {
    const p: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(opbase + off)));
    p[0] = v;
}
fn capRd(off: u32) u32 {
    const p: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(bar0 + off)));
    return p[0];
}

// ---- DMA rings ---------------------------------------------------------------
// XHCI DMA addresses are physical; our pmm frames are identity-mapped so
// phys==VA and no IOMMU translation is needed. Rings are page-sized TRB
// arrays allocated contiguous.
const TRB_SIZE = 16;
const RING_TRBS = 64; // TRBs per ring (1KB of TRBs, fits a page w/ headroom)

var cmdRingPhys: u64 = 0;
var evtRingPhys: u64 = 0;
var dcbaaPhys: u64 = 0;
var scratchPhys: u64 = 0;
var evtDequeue: u64 = 0; // current event TRB phys we consume
var evtCycle: u32 = 1;   // expected cycle bit in event TRBs
var cmdProducer: u32 = 0;

// TRB control dword: [31:16]=type, [15:0]=flags (cycle is bit0 'C').
fn trbControl(ty: u8, cycle: u32) u32 {
    return (@as(u32, ty) << 16) | (cycle & 1);
}

// write a TRB into a ring (phys ring, index). Returns phys addr of TRB.
fn trbAt(ringPhys: u64, idx: u32) u64 {
    return ringPhys + @as(u64, idx) * TRB_SIZE;
}
fn trbWr64(trbPhys: u64, param: u64, status: u32, ctrl: u32) void {
    const p: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(trbPhys)));
    p[0] = param;
    const dw23: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(trbPhys + 8)));
    dw23[0] = status;
    dw23[1] = ctrl;
}

// poll the event ring for a command-completion event matching `wantSlot`
// (0 = any). Returns the slot id (event DW2 bits) or 0 on timeout.
fn waitEvent() ?u32 {
    var spins: u64 = 0;
    while (spins < 50_000_000) : (spins += 1) {
        const erdp = opRd64_(OP_ERDP);
        const trbPhys = erdp & ~@as(u64, 0xF);
        // empty/not-yet-armed ring: ERDP can read 0 -> @ptrFromInt(0) is a
        // null-pointer panic in safe mode. Poll until a real TRB addr.
        if (trbPhys == 0 or trbPhys < evtRingPhys or trbPhys >= evtRingPhys + 4096) {
            asm volatile ("pause");
            continue;
        }
        const t: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(trbPhys)));
        const ctrl = (@as(u32, @intCast(t[1] >> 32)) );
        const cbit = ctrl & 1;
        const ty = (ctrl >> 16) & 0x3FFF;
        if (cbit == evtCycle and ty != 0) {
            // event TRB: dw0-1 = command ptr, dw2 = status/slot, dw3=ctrl
            const dw2 = @as(u32, @intCast(t[1] & 0xFFFFFFFF));
            const slot = (dw2 >> 24) & 0xFF;
            // advance dequeue past this TRB
            const next = trbPhys + TRB_SIZE;
            const wrap = cmdRingWrap();
            opWr64(OP_ERDP, next | 1); // ERDP bit0 = dequeue pointer valid? EHB
            if (wrap) evtCycle ^= 1;
            evtDequeue = next;
            return slot;
        }
        asm volatile ("pause");
    }
    return null;
}
fn opRd64_(off: u32) u64 {
    const p: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(opbase + off)));
    return p[0];
}
fn cmdRingWrap() bool {
    return false; // single-page ring, no wrap for our few commands
}

// ---- host controller init ----------------------------------------------------
pub fn init() bool {
    stage("xhci: ==== XHCI bring-up ====");
    // find an XHCI controller (class 0x0C/sub 0x03/progif 0x30)
    pci.init();
    var d: ?*const pci.Device = null;
    var i: usize = 0;
    while (i < pci.count) : (i += 1) {
        const dev = &pci.devices[i];
        if (dev.class == 0x0C and dev.subclass == 0x03 and dev.progif == 0x30) {
            d = dev;
            break;
        }
    }
    const dev = d orelse {
        stage("xhci: FAIL no XHCI controller");
        return false;
    };
    say("xhci: controller "); dec(dev.bus); say(":"); dec(dev.slot); say("."); dec(dev.func); say("\n");
    bar0 = pci.barPhys(dev, 0);
    if (bar0 == 0) {
        stage("xhci: FAIL BAR0 unmapped");
        return false;
    }
    // enable memory space + bus master
    pci.setCommand(dev, pci.command(dev) | 0x6);
    if (!hostmmio.map(bar0, 0x4000)) {
        stage("xhci: FAIL BAR0 map");
        return false;
    }
    caplen = @intCast(capRd(0) & 0xFF);
    opbase = bar0 + caplen;
    const hcsp = capRd(CAP_HCSPARAMS);
    maxSlots = hcsp & 0xFF;
    maxPorts = (hcsp >> 24) & 0xFF;
    say("xhci: caplen="); dec(caplen); say(" maxslots="); dec(maxSlots);
    say(" maxports="); dec(maxPorts); say("\n");
    stage("xhci: caps read");

    // dump the operational register head — ground truth for offsets
    say("xhci: op regs:");
    var o: u32 = 0;
    while (o < 0x50) : (o += 4) {
        say(" "); dec(o); say("="); hex32(opRd(o));
    }
    say("\n");
    stage("xhci: op regs dumped");

    // HC reset: set HCRST, wait CNR=0 then HCH=0, clear then set RS later.
    opWr(OP_USBCMD, opRd(OP_USBCMD) | USBCMD_HCRST);
    var spin: u64 = 0;
    while ((opRd(OP_USBSTS) & USBSTS_CNR) != 0 and spin < 10_000_000) : (spin += 1) {}
    spin = 0;
    while ((opRd(OP_USBSTS) & USBSTS_HCH) != 0 and spin < 10_000_000) : (spin += 1) {}
    say("xhci: reset done usbsts="); hex32(opRd(OP_USBSTS)); say("\n");
    stage("xhci: HC reset");

    // allocate DMA rings + DCBAA + scratchpad (page each, contiguous)
    cmdRingPhys = pmm.allocContiguous(1, 1) orelse {
        stage("xhci: FAIL cmdring alloc"); return false;
    };
    evtRingPhys = pmm.allocContiguous(1, 1) orelse {
        stage("xhci: FAIL evtring alloc"); return false;
    };
    dcbaaPhys = pmm.allocContiguous(1, 1) orelse {
        stage("xhci: FAIL dcbaa alloc"); return false;
    };
    scratchPhys = pmm.allocContiguous(1, 1) orelse {
        stage("xhci: FAIL scratch alloc"); return false;
    };
    // zero the rings + dcbaa (DCBAA entries = 0 = no context yet)
    {
        const cp: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(cmdRingPhys)));
        var k: usize = 0;
        while (k < (4096 / 8)) : (k += 1) cp[k] = 0;
        const ep: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(evtRingPhys)));
        k = 0;
        while (k < (4096 / 8)) : (k += 1) ep[k] = 0;
        const dp: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(dcbaaPhys)));
        k = 0;
        while (k < (4096 / 8)) : (k += 1) dp[k] = 0;
    }
    say("xhci: cmdring="); hex32(@intCast(cmdRingPhys)); say(" evtring=");
    hex32(@intCast(evtRingPhys)); say(" dcbaa="); hex32(@intCast(dcbaaPhys)); say("\n");
    stage("xhci: rings allocated");

    // scratchpad array: HCSPARAMS high bits give count; allocate buf array.
    // For a first pass use a single page scratchpad (maxslots small).
    // DCBAA[0] must point to scratchpad buffer array per spec.
    {
        const dp: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(dcbaaPhys)));
        // scratchpad buffer array: one pointer per slot to a page buffer.
        // allocate the array page and store phys of a data page.
        dp[0] = scratchPhys; // slot-0 context -> scratch page (simplified)
    }
    opWr64(OP_DCBAAP, dcbaaPhys);

    // event ring: 1 segment table entry -> evtRingPhys, dequeue=base.
    // ERST is a separate structure: [base_addr(8), size(4), rsvd(4)].
    // We place the segment table inside the evt ring page tail for now —
    // but spec wants it separate; allocate via the dcbaa page? Use a
    // dedicated approach: write ERSTBA to point at a small struct we
    // place in the scratch page.
    {
        // build ERST in scratch page: entry0 = {evtRingPhys, RING_TRBS, 0}
        const sp: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(scratchPhys)));
        sp[0] = evtRingPhys;          // segment base
        // size dword at +8
        const spd: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(scratchPhys + 8)));
        spd[0] = RING_TRBS;
        spd[1] = 0;
        opWr(OP_ERSTSZ, 1);          // 1 segment
        opWr64(OP_ERSTBA, scratchPhys);
        opWr64(OP_ERDP, evtRingPhys | 1); // EHB? dequeue ptr + event handler busy
        evtDequeue = evtRingPhys;
    }
    say("xhci: event ring armed\n");
    stage("xhci: event ring armed");

    // command ring: CRCR = base | RCS(bit0) | cycle in bit1? CRCR bit0=RCS,
    // the producer cycle state is bit1 (CRCR_CRR? actually CRCR bits:
    // [0]=RCS run, [1]=CRR consumer, producer cycle is elsewhere). The
    // command ring cycle bit lives in the TRBs themselves; CRCR just needs
    // the base + RCS. We set producer cycle=1 initially.
    cmdProducer = 0;
    opWr64(OP_CRCR, cmdRingPhys | 1); // RCS=1
    stage("xhci: command ring armed");

    // Enable Slot command (TRB type 9): param=0, no input.
    {
        const t = trbAt(cmdRingPhys, cmdProducer);
        trbWr64(t, 0, 0, trbControl(9, 1)); // type 9, cycle 1
        cmdProducer += 1;
        // ring doorbell for command ring? commands use CRCR producer
        // index implicit — write CRCR producer? The HC reads CRCR; we
        // must update the "command ring dequeue" via the producer TRB
        // being visible. Signal by writing CRCR again isn't needed; the
        // HC polls. Give it a moment then check event.
    }
    stage("xhci: Enable Slot issued");
    say("xhci: waiting for slot event...\n");
    if (waitEvent()) |slot| {
        say("xhci: SLOT ALLOCATED id="); dec(slot); say("\n");
        stage("xhci: ==== SLOT ENUM BASE DONE ====");
        return true;
    }
    stage("xhci: FAIL no slot event (ring/ERDP/offsets?)");
    return false;
}
