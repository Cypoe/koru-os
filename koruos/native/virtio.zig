// koru/native virtio — legacy virtio-blk (transitional PCI, I/O-port
// interface) as the koru-native provider of the uk_blkdev queue externs
// that koru/ext2 declares. Same interface, different substrate: on
// unikraft/qemu these symbols come from libukblkdev+libvirtio; here
// native-runtime serves them itself — the ext2 lift binds unchanged.
//
// Scope, honest: the device comes out of pci.zig's enumerated table —
// config cycles belong to the substrate — then the legacy I/O register
// window at BAR0, one virtqueue, synchronous requests (submit then
// park on the used ring). Transitional devices only — modern virtio-pci
// capability negotiation is a separate provider family.

const pci = @import("pci");

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
        : .{ .memory = true });
}
fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
        : .{ .memory = true });
}
fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "N{dx}" (port),
        : .{ .memory = true });
}
fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
        : .{ .memory = true });
}
fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "N{dx}" (port),
        : .{ .memory = true });
}
fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
        : .{ .memory = true });
}
fn mfence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

// ---- legacy virtio-blk --------------------------------------------------

const VENDOR: u16 = 0x1AF4;
const DEV_BLK: u16 = 0x1001; // transitional (legacy-capable) blk

const VIRTIO_FEATURES: u16 = 0x00; // u32 R  device feature bits
const VIRTIO_GFEATURES: u16 = 0x04; // u32 W  guest-accepted features
const VIRTIO_QUEUE_PFN: u16 = 0x08; // u32 W  ring phys >> 12
const VIRTIO_QUEUE_SIZE: u16 = 0x0C; // u16 R  descriptors per queue
const VIRTIO_QUEUE_SEL: u16 = 0x0E; // u16 W
const VIRTIO_NOTIFY: u16 = 0x10; // u16 W
const VIRTIO_STATUS: u16 = 0x12; // u8  RW
const VIRTIO_ISR: u16 = 0x13; // u8  R  (read-to-clear)
const VIRTIO_CONFIG: u16 = 0x14; // device config: capacity u64 at +0

const ST_ACK: u8 = 1;
const ST_DRIVER: u8 = 2;
const ST_DRIVER_OK: u8 = 4;

const DESC_NEXT: u16 = 1;
const DESC_WRITE: u16 = 2;

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const Avail = extern struct {
    flags: u16,
    idx: u16,
    // ring[N] u16 follows
};
const UsedElem = extern struct { id: u32, len: u32 };
const Used = extern struct {
    flags: u16,
    idx: u16,
    // ring[N] UsedElem follows
};

const BlkReqHdr = extern struct {
    type_: u32, // 0=IN(read) 1=OUT(write) 4=FLUSH
    reserved: u32,
    sector: u64,
};

var iobase: u16 = 0;
// INTx line from PCI config (0x3C lo byte); 0xFF = not yet discovered.
// The seam reads it to route the IRQ; ack reads the ISR (read-to-clear).
pub export var virtio_irq_line: u8 = 0xFF;
pub export var irq_pin: u8 = 0;
pub export var virtio_irq_count: u64 = 0;
pub export var blk_reqs: u64 = 0;
pub export var blk_parks: u64 = 0;
pub export var blk_yields: u64 = 0; // waits that scheduled, not halted
extern fn koru_irq_unmask(irq: u8) void;
extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;

pub export fn virtio_irq_ack() callconv(.c) void {
    if (iobase != 0) _ = inb(iobase + VIRTIO_ISR);
    virtio_irq_count += 1;
}
var qsize: u16 = 0;
var descs: [*]volatile Desc = undefined;
var avail: *volatile Avail = undefined;
var used: *volatile Used = undefined;
var used_elems: [*]volatile UsedElem = undefined;
var avail_ring: [*]volatile u16 = undefined;
var last_used_idx: u16 = 0;
var free_head: u16 = 0;
var pending_req: ?*BlkReq = null;
var req_hdr: BlkReqHdr = undefined;
var req_status: u8 = 0xFF;
var capacity: u64 = 0;
var device_found = false;

fn alignUp(x: usize, a: usize) usize {
    return (x + a - 1) & ~(a - 1);
}

fn findDevice() void {
    const d = pci.find(VENDOR, DEV_BLK) orelse return;
    const bar0 = d.bars[0];
    if ((bar0 & 1) == 0) return; // memory BAR → modern-only shape, not ours
    iobase = @intCast(bar0 & ~@as(u32, 3));
    // enable I/O space + bus mastering; clear INTx-disable (command bit
    // 10) so the line actually asserts
    pci.setCommand(d, (pci.command(d) & ~@as(u16, 0x400)) | 0x5);
    virtio_irq_line = d.irq_line;
    irq_pin = d.irq_pin;
    device_found = true;
}

// carve the ring out of a static arena — physically contiguous and below
// the 6 MiB identity map, which is what legacy QUEUE_PFN addressing needs.
var ring_mem: [16384]u8 align(4096) = undefined;

fn initQueue() void {
    outb(iobase + VIRTIO_STATUS, 0); // reset
    outb(iobase + VIRTIO_STATUS, ST_ACK);
    outb(iobase + VIRTIO_STATUS, ST_ACK | ST_DRIVER);
    _ = inl(iobase + VIRTIO_FEATURES);
    outl(iobase + VIRTIO_GFEATURES, 0); // accept no feature bits

    outw(iobase + VIRTIO_QUEUE_SEL, 0);
    qsize = inw(iobase + VIRTIO_QUEUE_SIZE);
    if (qsize < 4) qsize = 4;
    const n: usize = qsize;
    const avail_off = 16 * n;
    const used_off = alignUp(avail_off + 4 + 2 * n, 4096);
    const need = used_off + alignUp(4 + 8 * n, 4096);
    if (need > ring_mem.len) {
        // device offered more descriptors than the arena fits — cap is a
        // property of ring_mem, fail loudly at get() (device_found reset).
        device_found = false;
        return;
    }
    descs = @ptrCast(@alignCast(&ring_mem[0]));
    avail = @ptrCast(@alignCast(&ring_mem[avail_off]));
    avail_ring = @ptrFromInt(@intFromPtr(&ring_mem[avail_off + 4]));
    used = @ptrCast(@alignCast(&ring_mem[used_off]));
    used_elems = @ptrFromInt(@intFromPtr(&ring_mem[used_off + 4]));

    outl(iobase + VIRTIO_QUEUE_PFN, @intCast(@intFromPtr(&ring_mem[0]) >> 12));
    capacity = @as(u64, inl(iobase + VIRTIO_CONFIG)) |
        (@as(u64, inl(iobase + VIRTIO_CONFIG + 4)) << 32);
    // ring flags must be zero — VIRTQ_*_F_NO_INTERRUPT bits would suppress
    // the INTx assert we now rely on for the interrupt evidence
    avail.flags = 0;
    used.flags = 0;
    if (virtio_irq_line != 0xFF) koru_irq_unmask(virtio_irq_line);
}

fn blkStatus() void {
    outb(iobase + VIRTIO_STATUS, inb(iobase + VIRTIO_STATUS) | ST_DRIVER_OK);
}

// ---- the uk_blkdev extern surface the ext2 lift consumes -----------------

const BlkReq = extern struct {
    operation: c_int,
    start_sector: usize,
    nb_sectors: usize,
    aio_buf: ?*anyopaque,
    cb: ?*const fn (*BlkReq, ?*anyopaque) callconv(.c) void,
    cb_cookie: ?*anyopaque,
    state: c_int,
    result: c_int,
};

const Cap = extern struct {
    sectors: usize,
    ssize: usize,
    mode: c_int,
    max_sectors_per_req: usize,
    ioalign: u16,
};
const BlkPub = extern struct {
    submit_one: ?*anyopaque,
    finish_reqs: ?*anyopaque,
    _data: ?*anyopaque,
    capabilities: Cap,
};
const Dev = extern struct {
    pub_: BlkPub,
    configured: c_int,
};

var dev: Dev = .{
    .pub_ = .{
        .submit_one = null,
        .finish_reqs = null,
        ._data = null,
        .capabilities = .{
            .sectors = 0,
            .ssize = 512,
            .mode = 0,
            .max_sectors_per_req = 128,
            .ioalign = 512,
        },
    },
    .configured = 0,
};

fn ensureDev() bool {
    if (!device_found) findDevice();
    if (!device_found) return false;
    if (qsize == 0) {
        initQueue();
        if (!device_found) return false;
        dev.pub_.capabilities.sectors = @intCast(capacity);
        dev.pub_.submit_one = @ptrFromInt(1); // nonzero tokens; the lift
        dev.pub_.finish_reqs = @ptrFromInt(1); // reads capabilities only
    }
    return true;
}

pub export fn uk_blkdev_get(id: c_uint) callconv(.c) ?*anyopaque {
    if (id != 0) return null;
    if (!ensureDev()) return null;
    return @ptrCast(&dev);
}

pub export fn uk_blkdev_configure(d: ?*anyopaque, conf: ?*const anyopaque) callconv(.c) c_int {
    _ = d;
    _ = conf;
    return 0;
}

const QueueInfo = extern struct {
    nb_max: u16,
    nb_min: u16,
    nb_align: u16,
    nb_is_power_of_two: c_int,
};

pub export fn uk_blkdev_queue_get_info(d: ?*anyopaque, queue_id: u16, q_info: ?*QueueInfo) callconv(.c) c_int {
    _ = d;
    if (queue_id != 0 or q_info == null) return -22;
    q_info.?.* = .{ .nb_max = qsize, .nb_min = 1, .nb_align = 1, .nb_is_power_of_two = 1 };
    return 0;
}

pub export fn uk_blkdev_queue_configure(d: ?*anyopaque, queue_id: u16, nb_desc: u16, conf: ?*const anyopaque) callconv(.c) c_int {
    _ = d;
    _ = nb_desc;
    _ = conf;
    if (queue_id != 0) return -22;
    return 0;
}

pub export fn uk_blkdev_start(d: ?*anyopaque) callconv(.c) c_int {
    _ = d;
    blkStatus();
    return 0;
}

fn pushReq(req: *BlkReq) c_int {
    const n: usize = qsize;
    const d0: u16 = free_head;
    const d1: u16 = @intCast((d0 + 1) % n);
    const d2: u16 = @intCast((d0 + 2) % n);
    const is_flush = req.operation == 4;

    req_hdr = .{
        .type_ = @intCast(req.operation),
        .reserved = 0,
        .sector = @intCast(req.start_sector),
    };
    req_status = 0xFF;

    const hd: usize = d0;
    const sd: usize = d1;
    if (is_flush) {
        // flush carries no payload: header -> status only
        descs[hd] = .{ .addr = @intFromPtr(&req_hdr), .len = @sizeOf(BlkReqHdr), .flags = DESC_NEXT, .next = @intCast(sd) };
        descs[sd] = .{ .addr = @intFromPtr(&req_status), .len = 1, .flags = DESC_WRITE, .next = 0 };
    } else {
        const dd: usize = d2;
        descs[hd] = .{ .addr = @intFromPtr(&req_hdr), .len = @sizeOf(BlkReqHdr), .flags = DESC_NEXT, .next = @intCast(dd) };
        descs[dd] = .{
            .addr = @intFromPtr(req.aio_buf.?),
            .len = @intCast(req.nb_sectors * 512),
            .flags = DESC_NEXT | (if (req.operation == 0) DESC_WRITE else @as(u16, 0)),
            .next = @intCast(sd),
        };
        descs[sd] = .{ .addr = @intFromPtr(&req_status), .len = 1, .flags = DESC_WRITE, .next = 0 };
    }

    mfence();
    const ai = avail.idx;
    avail_ring[@as(usize, ai) % n] = d0;
    mfence();
    avail.idx = ai +% 1;
    mfence();
    outw(iobase + VIRTIO_NOTIFY, 0);

    free_head = @intCast((d0 + 3) % n);
    return 0;
}

// The queue carries ONE outstanding request (pending_req/req_hdr/
// req_status are single slots), so submission itself must serialize:
// a bkl-held context that kblocks on .blk drops the lock, and a second
// context's submit would overwrite pending_req — the first request then
// retires uncredited and its waiter parks forever. blk_mu is the silo's
// own lock; waiters queue on .blkq (kind 2) so they yield like any other
// device wait instead of spinning.
var blk_mu: u8 = 0;

extern fn koru_dev_wake(kind: u8) callconv(.c) void;

fn waitBlkMu() void {
    while (@atomicLoad(u8, &blk_mu, .acquire) != 0) {
        const flags = asm volatile ("pushfq\n\tpop %[f]"
            : [f] "=r" (-> u64)
            :
            : .{ .memory = true });
        asm volatile ("cli" ::: .{ .memory = true });
        if (@atomicLoad(u8, &blk_mu, .acquire) != 0) {
            if (koru_dev_sleep(2) != 0) {
                blk_yields += 1;
                continue;
            }
            blk_parks += 1;
            asm volatile ("sti\n\thlt" ::: .{ .memory = true });
        }
        if (flags & 0x200 == 0) asm volatile ("cli" ::: .{ .memory = true });
    }
    @atomicStore(u8, &blk_mu, 1, .release);
}

pub export fn uk_blkdev_queue_submit_one(d: ?*anyopaque, queue_id: u16, req: ?*BlkReq) callconv(.c) c_int {
    _ = d;
    if (queue_id != 0 or req == null) return -22;
    waitBlkMu();
    const r = pushReq(req.?);
    if (r != 0) {
        @atomicStore(u8, &blk_mu, 0, .release);
        koru_dev_wake(2);
        return r;
    }
    pending_req = req;
    blk_reqs += 1;
    return 1; // STATUS_SUCCESS bit, as the lift checks it
}

// Park until the next interrupt. Two waits exist: inside a live epoch
// (syscall context — syscall's SFMASK already masked IF, which is why
// this runs cli'd by default there) the wait is a real kernel-context
// block via koru_dev_sleep — the roster schedules through the DMA window
// and the completion's IRQ resumes us mid-call. Outside an epoch (kmain
// mount) cli, re-read the used index under the mask, then sti;hlt —
// sti and hlt execute as one atomic enable-and-sleep, so a completion
// landing between the caller's check and here cannot be slept past. A
// caller with IF=0 and no epoch cannot wake — it polls.
// kind 0 = .blk (the WaitKind device arms are mirrored there).
extern fn koru_dev_sleep(kind: u8) callconv(.c) c_int;

fn parkOnce() void {
    const flags = asm volatile ("pushfq\n\tpop %[f]"
        : [f] "=r" (-> u64)
        :
        : .{ .memory = true });
    asm volatile ("cli" ::: .{ .memory = true });
    if (used.idx == last_used_idx) {
        if (koru_dev_sleep(0) != 0) { // mid-call block — resumed with IF=1
            blk_yields += 1;
            return;
        }
        blk_parks += 1;
        // sti;hlt under a bkl hold is legal via the dispatch's nested arm:
        // the completion IRQ runs on the holder's stack without re-locking,
        // and the hlt gives the cpu a real idle exit — the IF=0 poll that
        // used to live here starved TCG's completion path (no exits meant
        // the used-ring update never got serviced).
        asm volatile ("sti\n\thlt" ::: .{ .memory = true });
        if (flags & 0x200 == 0) asm volatile ("cli" ::: .{ .memory = true });
    } else if (flags & 0x200 != 0) {
        asm volatile ("sti" ::: .{ .memory = true });
    }
}

pub export fn uk_blkdev_queue_finish_reqs(d: ?*anyopaque, queue_id: u16) callconv(.c) c_int {
    _ = d;
    if (queue_id != 0) return -22;
    // ISR is the IRQ handler's channel — reading it here (read-to-clear)
    // would drop INTx mid-assertion and the PIC reports a spurious IRQ15
    var ui = used.idx;
    if (ui == last_used_idx) {
        // nothing retired — park on the next interrupt instead of
        // returning into the lift's poll loop; each empty finish_reqs is
        // one hlt = one delivered vector, so the retry loop is paced by
        // interrupts rather than burning the core
        parkOnce();
        ui = used.idx;
        if (ui == last_used_idx) return 0;
    }
    last_used_idx = ui;
    if (pending_req) |req| {
        req.state = 0; // REQ_FINISHED
        req.result = if (req_status == 0) 0 else -5;
        pending_req = null;
        @atomicStore(u8, &blk_mu, 0, .release);
        koru_dev_wake(2); // a submitter queued behind us can enter now
        if (req.cb) |cb| cb(req, req.cb_cookie);
    }
    return 0;
}

pub export fn uk_blkdev_stop(d: ?*anyopaque) callconv(.c) c_int {
    _ = d;
    return 0;
}
pub export fn uk_blkdev_queue_unconfigure(d: ?*anyopaque, queue_id: u16) callconv(.c) c_int {
    _ = d;
    _ = queue_id;
    return 0;
}
pub export fn uk_blkdev_unconfigure(d: ?*anyopaque) callconv(.c) c_int {
    _ = d;
    // interrupt-driven evidence, printed at unmount: each park is one
    // slept-until-a-vector window — parks staying in single digits per
    // request is the "driven, not assisted" claim made measurable
    koru_say("blk: reqs=");
    koru_putdec(blk_reqs);
    koru_say(" parks=");
    koru_putdec(blk_parks);
    koru_say(" yields=");
    koru_putdec(blk_yields);
    koru_say(" irqs=");
    koru_putdec(virtio_irq_count);
    koru_say("\n");
    return 0;
}
