// koru/native gpu — virtio-gpu 2D as a display driver silo.
//
// Modern-only device (1af4:1050): the register map comes from virtiopci's
// vendor-cap windows, interrupts are MSI-X (the consumer that makes
// pci.zig's msix helpers measured), and commands ride the controlq —
// out-descriptor carries the request, in-descriptor the response header.
//
// The 2D model is a guest-owned pixel resource: CREATE_2D names it,
// ATTACH_BACKING binds guest pages (a scatter list — our two pmm 2MiB
// frames are non-contiguous and that's exactly what the entry list is
// for), SET_SCANOUT binds it to the display, TRANSFER_TO_HOST_2D uploads
// a damaged rect, RESOURCE_FLUSH commits it to the scanout. Writes go
// to backing memory; `present` is the commit — the same surface
// contract the fb seam declares, here made of real device verbs.

const pci = @import("pci");
const vp = @import("virtiopci");
const mmio = @import("mmio");
const pmm = @import("pmm");

extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;
extern fn koru_dev_sleep(kind: u8) callconv(.c) c_int;

const VENDOR: u16 = 0x1AF4;
const DEV_GPU: u16 = 0x1050; // modern virtio-gpu (non-transitional)

const T_GET_DISPLAY_INFO: u32 = 0x0100;
const T_RESOURCE_CREATE_2D: u32 = 0x0101;
const T_SET_SCANOUT: u32 = 0x0103;
const T_RESOURCE_FLUSH: u32 = 0x0104;
const T_TRANSFER_TO_HOST_2D: u32 = 0x0105;
const T_ATTACH_BACKING: u32 = 0x0106;
const R_OK_NODATA: u32 = 0x1100;
const R_OK_DISPLAY_INFO: u32 = 0x1101;

const FMT_B8G8R8X8: u32 = 2; // XRGB8888 — matches the fb seam's 0x00RRGGBB
const MSIX_VEC: u8 = 0x30; // first IDT vector above the PIC range

const Hdr = extern struct {
    type_: u32,
    flags: u32,
    fence_id: u64,
    ctx_id: u32,
    ring_idx: u8,
    pad: [3]u8,
};
const Rect = extern struct { x: u32, y: u32, width: u32, height: u32 };
const PMode = extern struct { r: Rect, enabled: u32, flags: u32 };
const DisplayInfo = extern struct { hdr: Hdr, pmodes: [16]PMode };
const AttachBacking = extern struct { hdr: Hdr, resource_id: u32, nr_entries: u32 };
const MemEntry = extern struct { addr: u64, length: u32, padding: u32 };
const Create2D = extern struct {
    hdr: Hdr,
    resource_id: u32,
    format: u32,
    width: u32,
    height: u32,
};
const SetScanout = extern struct { hdr: Hdr, r: Rect, scanout_id: u32, resource_id: u32 };
const Transfer = extern struct {
    hdr: Hdr,
    r: Rect,
    offset: u64,
    resource_id: u32,
    padding: u32,
};
const Flush = extern struct { hdr: Hdr, r: Rect, resource_id: u32, padding: u32 };

// the seam reads these from user.zig's MSI dispatch arm
pub export var gpu_msix_vec: u8 = 0xFF;
pub export var gpu_msix_seen: u64 = 0;
pub export fn gpu_irq_ack() callconv(.c) void {
    if (dev.isr != 0) _ = vp.isrRead(&dev); // read-to-clear
    gpu_cmd_irqs += 1;
}

var dev: vp.Dev = .{ .pdev = undefined };
var ctlq: vp.Queue = undefined;
var present_dev = false;

// ring + payload memory: static, below the identity map — modern queue
// addressing takes full phys addrs, no PFN constraint, but the addresses
// must still be real phys under our identity mapping.
var qmem: [8192]u8 align(4096) = undefined;
var cmdbuf: [512]u8 align(16) = undefined;
var respbuf: [512]u8 align(16) = undefined;
var gpu_cmd_n: u64 = 0;
var gpu_cmd_irqs: u64 = 0;

// display state
var w: u32 = 0;
var h: u32 = 0;
var pages: [8]u64 = .{0} ** 8; // backing 2MiB frames, phys (identity VA)
var pages_n: u32 = 0;
const RES_ID: u32 = 1;
const SCANOUT: u32 = 0;

fn hdr(ty: u32) Hdr {
    return .{ .type_ = ty, .flags = 0, .fence_id = 0, .ctx_id = 0, .ring_idx = 0, .pad = .{0} ** 3 };
}

// One command, one chain: [out req][in resp]. Synchronous — park until
// the used ring retires it (MSI-X wakes the .gpu wait; outside an epoch
// the hlt path in virtio.zig's shape: cli-check-sti;hlt).
fn cmd(out_len: usize, in_len: usize, want: u32) bool {
    const n: usize = ctlq.size;
    const d0 = ctlq.free_head;
    const d1 = (d0 + 1) % @as(u16, @intCast(n));
    ctlq.descs[d0] = .{
        .addr = @intFromPtr(&cmdbuf[0]),
        .len = @intCast(out_len),
        .flags = vp.DESC_NEXT,
        .next = d1,
    };
    ctlq.descs[d1] = .{
        .addr = @intFromPtr(&respbuf[0]),
        .len = @intCast(in_len),
        .flags = vp.DESC_WRITE,
        .next = 0,
    };
    asm volatile ("mfence" ::: .{ .memory = true });
    const ai = ctlq.avail_idx.*;
    ctlq.avail_ring[ai % @as(u16, @intCast(n))] = d0;
    asm volatile ("mfence" ::: .{ .memory = true });
    ctlq.avail_idx.* = ai +% 1;
    asm volatile ("mfence" ::: .{ .memory = true });
    vp.kick(&dev, &ctlq);
    ctlq.free_head = (d0 + 2) % @as(u16, @intCast(n));
    gpu_cmd_n += 1;

    // park until the used ring retires — the MSI-X delivery wakes us.
    // sti;hlt is legal even under a bkl hold (the dispatch's nested arm
    // runs the IRQ without re-locking), and the hlt is what lets the
    // device's completion path run — a masked poll starves it.
    const flags = asm volatile ("pushfq\n\tpop %[f]"
        : [f] "=r" (-> u64)
        :
        : .{ .memory = true });
    var guard: u32 = 0;
    while (true) {
        asm volatile ("cli" ::: .{ .memory = true });
        if (ctlq.used_idx.* != ctlq.last_used) break;
        if (koru_dev_sleep(1) != 0) continue; // blocked-and-woke under bkl
        asm volatile ("sti\n\thlt" ::: .{ .memory = true });
        guard += 1;
        if (guard > 4_000_000) {
            if (flags & 0x200 == 0) asm volatile ("cli" ::: .{ .memory = true });
            koru_say("vgpu: command timeout\n");
            return false;
        }
    }
    if (flags & 0x200 != 0) asm volatile ("sti" ::: .{ .memory = true });
    ctlq.last_used = ctlq.used_idx.*;
    const r: *volatile Hdr = @ptrCast(@alignCast(&respbuf[0]));
    return r.type_ == want;
}

fn getDisplayInfo() bool {
    const c: *Hdr = @ptrCast(@alignCast(&cmdbuf[0]));
    c.* = hdr(T_GET_DISPLAY_INFO);
    if (!cmd(@sizeOf(Hdr), @sizeOf(DisplayInfo), R_OK_DISPLAY_INFO)) return false;
    const di: *volatile DisplayInfo = @ptrCast(@alignCast(&respbuf[0]));
    var pick: usize = 16;
    var i: usize = 0;
    while (i < 16) : (i += 1)
        if (di.pmodes[i].enabled != 0 and di.pmodes[i].r.width != 0) {
            pick = i;
            break;
        };
    if (pick == 16) pick = 0; // none enabled — use slot 0, set_scanout makes it real
    w = di.pmodes[pick].r.width;
    h = di.pmodes[pick].r.height;
    if (w == 0 or h == 0) {
        w = 1024;
        h = 768;
    }
    koru_say("vgpu: display info scanout0 ");
    koru_putdec(w);
    koru_say("x");
    koru_putdec(h);
    koru_say("\n");
    return true;
}

fn createBacking() bool {
    const need: u64 = @as(u64, w) * h * 4;
    pages_n = @intCast((need + 0x1FFFFF) >> 21);
    if (pages_n == 0 or pages_n > pages.len) {
        koru_say("vgpu: backing too large\n");
        return false;
    }
    // pmm frames are non-contiguous — the attach entry list is the
    // designed mechanism for exactly that scatter.
    var i: u32 = 0;
    while (i < pages_n) : (i += 1) {
        pages[i] = pmm.alloc2M() orelse {
            koru_say("vgpu: pmm out of 2M frames\n");
            return false;
        };
    }
    const c: *Create2D = @ptrCast(@alignCast(&cmdbuf[0]));
    c.* = .{ .hdr = hdr(T_RESOURCE_CREATE_2D), .resource_id = RES_ID, .format = FMT_B8G8R8X8, .width = w, .height = h };
    if (!cmd(@sizeOf(Create2D), @sizeOf(Hdr), R_OK_NODATA)) return false;

    const a: *AttachBacking = @ptrCast(@alignCast(&cmdbuf[0]));
    a.* = .{ .hdr = hdr(T_ATTACH_BACKING), .resource_id = RES_ID, .nr_entries = pages_n };
    const ents: [*]MemEntry = @ptrCast(@alignCast(cmdbuf[@sizeOf(AttachBacking)..].ptr));
    i = 0;
    var left = need;
    while (i < pages_n) : (i += 1) {
        const l: u32 = @intCast(@min(left, 0x200000));
        ents[i] = .{ .addr = pages[i], .length = l, .padding = 0 };
        left -= l;
    }
    if (!cmd(@sizeOf(AttachBacking) + pages_n * @sizeOf(MemEntry), @sizeOf(Hdr), R_OK_NODATA)) return false;

    const s: *SetScanout = @ptrCast(@alignCast(&cmdbuf[0]));
    s.* = .{
        .hdr = hdr(T_SET_SCANOUT),
        .r = .{ .x = 0, .y = 0, .width = w, .height = h },
        .scanout_id = SCANOUT,
        .resource_id = RES_ID,
    };
    return cmd(@sizeOf(SetScanout), @sizeOf(Hdr), R_OK_NODATA);
}

// ---- the fb seam's backend ops -------------------------------------------

pub fn fbInfo(out: anytype) u8 {
    if (!present_dev) return 0;
    out.* = .{ .width = w, .height = h, .pitch = w * 4, .bpp = 32 };
    return 1;
}

fn pxAddr(x: u32, y: u32) ?*volatile u32 {
    if (x >= w or y >= h) return null;
    const off: u64 = @as(u64, y) * w * 4 + @as(u64, x) * 4;
    const page = off >> 21;
    if (page >= pages_n) return null;
    return @ptrFromInt(@as(usize, @intCast(pages[page] + (off & 0x1FFFFF))));
}

pub fn fbPx(x: u32, y: u32, color: u32) u8 {
    const p = pxAddr(x, y) orelse return 0;
    p.* = color;
    return 1;
}

pub fn fbFill(x: u32, y: u32, fw: u32, fh: u32, color: u32) u8 {
    if (!present_dev) return 0;
    const x1 = @min(x + fw, w);
    const y1 = @min(y + fh, h);
    var yy = @min(y, h);
    while (yy < y1) : (yy += 1) {
        var xx = @min(x, w);
        while (xx < x1) : (xx += 1) {
            (pxAddr(xx, yy) orelse return 0).* = color;
        }
    }
    return 1;
}

// present IS the commit: TRANSFER uploads the damaged rect to the host
// resource, FLUSH pushes it to the scanout. On an LFB this is implicit;
// here it's the two real verbs.
var reported = false;
pub fn fbPresent(x: u32, y: u32, pw: u32, ph: u32) u8 {
    if (!present_dev) return 0;
    const r: Rect = .{ .x = x, .y = y, .width = @min(pw, w - x), .height = @min(ph, h - y) };
    // offset is a BYTE offset into the strided backing where the rect's
    // top-left pixel lives — QEMU reads `offset + stride*h` per row, so
    // 0 means "rect (0,0,w,h)", not "this rect". A full-frame transfer is
    // coincidentally right at 0; any sub-rect needs the real offset.
    const off = (@as(u64, r.y) * w + r.x) * 4;
    const t: *Transfer = @ptrCast(@alignCast(&cmdbuf[0]));
    t.* = .{ .hdr = hdr(T_TRANSFER_TO_HOST_2D), .r = r, .offset = off, .resource_id = RES_ID, .padding = 0 };
    if (!cmd(@sizeOf(Transfer), @sizeOf(Hdr), R_OK_NODATA)) return 0;
    const f: *Flush = @ptrCast(@alignCast(&cmdbuf[0]));
    f.* = .{ .hdr = hdr(T_RESOURCE_FLUSH), .r = r, .resource_id = RES_ID, .padding = 0 };
    if (!cmd(@sizeOf(Flush), @sizeOf(Hdr), R_OK_NODATA)) return 0;
    if (!reported) { reported = true; stats(); }
    return 1;
}

// ---- init: table → caps → features → queue + MSI-X → modeset -------------

pub fn init() bool {
    const pdev = pci.find(VENDOR, DEV_GPU) orelse return false;
    koru_say("vgpu: device ");
    koru_putdec(pdev.slot);
    koru_say(".0 in pci table\n");
    dev = vp.open(pdev) orelse return false;
    koru_say("vgpu: windows common+notify+isr mapped, nqueues=");
    koru_putdec(dev.nqueues);
    koru_say("\n");
    vp.statusBegin(&dev);
    // VERSION_1 (bit 32 → hi dword bit 0) is mandatory for modern; the
    // 2D path needs no optional features.
    if (!vp.negFeatures(&dev, 0, 1)) {
        koru_say("vgpu: FEATURES_OK refused\n");
        return false;
    }
    koru_say("vgpu: features negotiated (VERSION_1)\n");

    // MSI-X: table walks back through the device's own BAR record; one
    // vector (0x30) serves the ctrlq — config changes get NO_VECTOR.
    const mt = pci.msixTable(pdev) orelse {
        koru_say("vgpu: no MSI-X cap\n");
        return false;
    };
    const tphys = pci.barPhys(pdev, mt.bar) + mt.off;
    if (!mmio.map(tphys, 0x1000)) return false;
    const tva: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(tphys)));
    pci.msixSetEntry(tva, 0, MSIX_VEC);

    // ring layout inside qmem: descs(16*n) | avail(6+2n) | used(page-aligned)
    const n: u16 = 8;
    const avail_off = 16 * @as(usize, n);
    const used_off = (avail_off + 4 + 2 * @as(usize, n) + 4095) & ~@as(usize, 4095);
    ctlq = .{
        .idx = 0,
        .size = n,
        .descs = @ptrCast(@alignCast(&qmem[0])),
        .avail_flags = @ptrCast(@alignCast(&qmem[avail_off])),
        .avail_idx = @ptrCast(@alignCast(&qmem[avail_off + 2])),
        .avail_ring = @ptrFromInt(@intFromPtr(&qmem[avail_off + 4])),
        .used_base = @intFromPtr(&qmem[used_off]),
        .used_idx = @ptrCast(@alignCast(&qmem[used_off + 2])),
        .used_ring = @ptrFromInt(@intFromPtr(&qmem[used_off + 4])),
        .notify = 0,
    };
    if (!vp.queueBind(&dev, &ctlq, 0)) {
        koru_say("vgpu: queue bind refused\n");
        return false;
    }
    vp.setConfigVector(&dev, vp.MSIX_NO_VECTOR);
    if (!pci.msixEnable(pdev)) {
        koru_say("vgpu: MSI-X enable refused\n");
        return false;
    }
    gpu_msix_vec = MSIX_VEC;
    vp.driverOk(&dev);
    koru_say("vgpu: msix vec=");
    koru_putdec(MSIX_VEC);
    koru_say(" armed — ctrlq live\n");

    if (!getDisplayInfo()) return false;
    if (!createBacking()) return false;
    present_dev = true;
    koru_say("vgpu: resource + scanout live — backing ");
    koru_putdec(pages_n);
    koru_say("x2M frames\n");
    return true;
}

// final counters for the gate — read on serial at shutdown-ish
pub fn stats() void {
    koru_say("vgpu: cmds=");
    koru_putdec(gpu_cmd_n);
    koru_say(" msix=");
    koru_putdec(gpu_msix_seen);
    koru_say("\n");
}

const std = @import("std");
