// koru/native net — the REAL network stack: virtio-net on the modern
// virtiopci transport plus an owned eth/ARP/IPv4/ICMP/TCP(client)
// engine. The COM2 relay stays the delegated provider realization —
// same socket seam, different wire truth. user.zig's SockPair picks
// the provider by what armed: this file answers "present" once the
// device negotiates.
//
// Scope, honest: static IPv4 (slirp's fixed 10.0.2.15/24, gw .2 — DHCP
// is a named gap), TCP client-side only (listen lands with a server
// oracle), no out-of-order reassembly (a dup-ACK + drop — slirp's LAN
// doesn't reorder; the gap is documented not hidden), ICMP echo
// request/reply for the ping evidence, UDP declared but unbuilt.

const pci = @import("pci");
const vp = @import("virtiopci");
const mmio = @import("mmio");

extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;

// ---- device --------------------------------------------------------------

const NET_VEC: u8 = 0x31; // MSI-X doorbell — gpu owns 0x30
pub export var net_msix_vec: u8 = 0xFF;
pub export var net_msix_seen: u64 = 0;
pub export fn net_irq_ack() callconv(.c) void {
    _ = vp.isrRead(&dev);
    net_msix_seen += 1;
}

var dev: vp.Dev = undefined;
var armed: bool = false;
pub fn nativeUp() bool {
    return armed;
}

const NRX: u16 = 8;
const NTX: u16 = 8;
var rxq: vp.Queue = undefined;
var txq: vp.Queue = undefined;
var rxqmem: [8 * 1024]u8 align(4096) = undefined;
var txqmem: [8 * 1024]u8 align(4096) = undefined;
// wire buffers: 10B virtio hdr + frame room
var rxbuf: [NRX][2048]u8 align(16) = undefined;
var txbuf: [NTX][2048]u8 align(16) = undefined;
var tx_busy: [NTX]bool = .{false} ** NTX;

var my_mac: [6]u8 = undefined;

fn queueMem(mem: []align(4096) u8, idx: u16, n: u16) vp.Queue {
    const avail_off = 16 * @as(usize, n);
    const used_off = (avail_off + 4 + 2 * @as(usize, n) + 4095) & ~@as(usize, 4095);
    return .{
        .idx = idx,
        .size = n,
        .descs = @ptrCast(@alignCast(&mem[0])),
        .avail_flags = @ptrCast(@alignCast(&mem[avail_off])),
        .avail_idx = @ptrCast(@alignCast(&mem[avail_off + 2])),
        .avail_ring = @ptrFromInt(@intFromPtr(&mem[avail_off + 4])),
        .used_base = @intFromPtr(&mem[used_off]),
        .used_idx = @ptrCast(@alignCast(&mem[used_off + 2])),
        .used_ring = @ptrFromInt(@intFromPtr(&mem[used_off + 4])),
        .notify = 0,
    };
}

// Probe + arm. Transitional (1af4:1000) or modern (1af4:1041) — the
// caps walk doesn't care. Returns false silently-absent like the COM2
// probe: no device, no stack, nothing armed.
fn devInit() bool {
    const pdev = pci.find(0x1AF4, 0x1041) orelse
        (pci.find(0x1AF4, 0x1000) orelse return false);
    dev = vp.open(pdev) orelse return false;
    vp.statusBegin(&dev);
    // VERSION_1 (hi bit0) is mandatory on modern; MAC (bit5) so our
    // address comes from the device not a guess. Nothing else — no
    // mergeable rx, no checksum offload: plain frames.
    if (!vp.negFeatures(&dev, 1 << 5, 1)) {
        koru_say("net: FEATURES_OK refused\n");
        return false;
    }
    const mc: *volatile [6]u8 = @ptrFromInt(dev.dcfg);
    my_mac = mc.*;
    koru_say("net: virtio-net mac=");
    var mi: usize = 0;
    while (mi < 6) : (mi += 1) {
        if (mi > 0) koru_say(":");
        koru_putdec(my_mac[mi]);
    }
    koru_say("\n");
    // MSI-X on the gpu pattern: one vector for both queues — the door
    // drains both rings regardless of which knocked.
    const mt = pci.msixTable(pdev) orelse {
        koru_say("net: no MSI-X table\n");
        return false;
    };
    const tphys = pci.barPhys(pdev, mt.bar) + mt.off;
    if (!mmio.map(tphys, 0x1000)) {
        koru_say("net: msix table map refused\n");
        return false;
    }
    const tva: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(tphys)));
    pci.msixSetEntry(tva, 0, NET_VEC);
    rxq = queueMem(&rxqmem, 0, NRX);
    txq = queueMem(&txqmem, 1, NTX);
    if (!vp.queueBind(&dev, &rxq, 0) or !vp.queueBind(&dev, &txq, 0)) {
        koru_say("net: queue bind refused\n");
        return false;
    }
    vp.setConfigVector(&dev, vp.MSIX_NO_VECTOR);
    if (!pci.msixEnable(pdev)) {
        koru_say("net: MSI-X refused\n");
        return false;
    }
    // post the rx buffers: one WRITE desc each, id == buf index
    var i: u16 = 0;
    while (i < NRX) : (i += 1) {
        rxq.descs[i] = .{ .addr = @intFromPtr(&rxbuf[i]), .len = 2048,
            .flags = vp.DESC_WRITE, .next = 0 };
        rxq.avail_ring[i] = i;
    }
    rxq.avail_idx.* = NRX;
    vp.driverOk(&dev);
    net_msix_vec = NET_VEC;
    armed = true;
    koru_say("net: queues live — rx bufs posted, driver_ok\n");
    arpRequest(GW_IP); // prime the neighbor — the first connect's
                       // SYN shouldn't wait on resolve
    icmpEcho(GW_IP); // the ARP+ICMP proof rides the boot log —
                     // slirp answers its own address
    return true;
}

// ---- wire primitives ------------------------------------------------------

fn ethTx(dst: [6]u8, etype: u16, payload: []const u8) bool {
    // one flat buffer: virtio hdr (12B under VERSION_1 — the modern
    // header carries num_buffers) + eth hdr + payload — a single READ
    // desc per packet, desc d pinned to txbuf[d]
    var d: u16 = NTX;
    for (0..NTX) |i| if (!tx_busy[i]) {
        d = @intCast(i);
        break;
    };
    if (d == NTX) return false; // all bufs in flight — retry next pass
    const b = &txbuf[d];
    @memset(b[0..12], 0); // virtio_net_hdr — no gso, no csum offload
    @memcpy(b[12..18], &dst);
    @memcpy(b[18..24], &my_mac);
    b[24] = @intCast(etype >> 8);
    b[25] = @intCast(etype & 0xFF);
    @memcpy(b[26 .. 26 + payload.len], payload);
    tx_busy[d] = true;
    txq.descs[d] = .{ .addr = @intFromPtr(b), .len = @intCast(26 + payload.len),
        .flags = 0, .next = 0 };
    const ai = txq.avail_idx.*;
    txq.avail_ring[ai % NTX] = d;
    asm volatile ("mfence" ::: .{ .memory = true });
    txq.avail_idx.* = ai + 1;
    vp.kick(&dev, &txq);
    return true;
}

fn txReap() void {
    while (txq.last_used != txq.used_idx.*) {
        const e = txq.used_ring[txq.last_used % NTX];
        tx_busy[e.id] = false; // desc d rode txbuf[d] — both free
        txq.last_used +%= 1;
    }
}

pub export var ping_seen: u64 = 0;

// ---- byte-order + checksums ----------------------------------------------

fn rd16(b: []const u8) u16 {
    return (@as(u16, b[0]) << 8) | b[1];
}
fn rd32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) |
        (@as(u32, b[2]) << 8) | b[3];
}

fn csum(b: []const u8) u16 {
    var s: u64 = 0;
    var i: usize = 0;
    while (i + 1 < b.len) : (i += 2) s += (@as(u64, b[i]) << 8) | b[i + 1];
    if (i < b.len) s += @as(u64, b[i]) << 8;
    while (s >> 16 != 0) s = (s & 0xFFFF) + (s >> 16);
    return ~@as(u16, @intCast(s));
}

fn tcpCsum(src: [4]u8, dst: [4]u8, seg: []const u8) u16 {
    var s: u64 = 0;
    // pseudo-header: src+dst+zero+proto+len
    s += (@as(u64, src[0]) << 8) | src[1];
    s += (@as(u64, src[2]) << 8) | src[3];
    s += (@as(u64, dst[0]) << 8) | dst[1];
    s += (@as(u64, dst[2]) << 8) | dst[3];
    s += 6; // proto
    s += seg.len;
    var i: usize = 0;
    while (i + 1 < seg.len) : (i += 2) s += (@as(u64, seg[i]) << 8) | seg[i + 1];
    if (i < seg.len) s += @as(u64, seg[i]) << 8;
    while (s >> 16 != 0) s = (s & 0xFFFF) + (s >> 16);
    return ~@as(u16, @intCast(s));
}

// ---- stack state -----------------------------------------------------------

const MY_IP = [4]u8{ 10, 0, 2, 15 };
const GW_IP = [4]u8{ 10, 0, 2, 2 };

const ArpEnt = struct { ip: [4]u8, mac: [6]u8, live: bool = false };
var arps: [4]ArpEnt = [_]ArpEnt{ .{ .ip = .{0} ** 4, .mac = .{0} ** 6 } } ** 4;

fn arpFind(ip: [4]u8) ?[6]u8 {
    for (&arps) |*e| if (e.live and std.mem.eql(u8, &e.ip, &ip)) return e.mac;
    return null;
}
fn arpLearn(ip: [4]u8, mac: [6]u8) void {
    var fresh = false;
    for (&arps) |*e| {
        if (e.live and std.mem.eql(u8, &e.ip, &ip)) {
            e.mac = mac;
            break;
        }
    } else {
        var slot: ?*ArpEnt = null;
        for (&arps) |*e| {
            if (!e.live) {
                slot = e;
                break;
            }
        }
        if (slot) |e| {
            e.ip = ip;
            e.mac = mac;
            e.live = true;
        } else {
            arps[0] = .{ .ip = ip, .mac = mac, .live = true }; // evict oldest slot
        }
        fresh = true;
    }
    if (!fresh) return;
    koru_say("net: arp learned ");
    koru_putdec(ip[0]);
    koru_say(".");
    koru_putdec(ip[1]);
    koru_say(".");
    koru_putdec(ip[2]);
    koru_say(".");
    koru_putdec(ip[3]);
    koru_say("\n");
    // a pending echo that died on the ARP miss gets its wire back the
    // moment the neighbor resolves — the boot epoch is ~6 ticks, too
    // short for the sweep's retry window to matter
    if (echo_pending > 0 and echo_retries < 6) {
        echo_retries += 1;
        echo_at = last_tick;
        echoTx();
    }
}

fn arpRequest(ip: [4]u8) void {
    var p: [28]u8 = undefined;
    p[0] = 0;
    p[1] = 1; // htype eth
    p[2] = 0x08;
    p[3] = 0; // ptype ipv4
    p[4] = 6;
    p[5] = 4;
    p[6] = 0;
    p[7] = 1; // request
    @memcpy(p[8..14], &my_mac);
    @memcpy(p[14..18], &MY_IP);
    @memset(p[18..24], 0);
    @memcpy(p[24..28], &ip);
    _ = ethTx(.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, 0x0806, &p);
}

// the wire neighbor for a dst: subnet-local answers its own ARP,
// everything else rides the gateway's — slirp answers both shapes.
fn neighborFor(dst: [4]u8) [4]u8 {
    if (dst[0] == MY_IP[0] and dst[1] == MY_IP[1] and dst[2] == MY_IP[2])
        return dst;
    return GW_IP;
}

var ip_id: u16 = 1;

fn ipTx(dst: [4]u8, proto: u8, payload: []const u8) bool {
    const nh = neighborFor(dst);
    const dmac = arpFind(nh) orelse {
        arpRequest(nh); // resolve first — the caller's retransmit sweeps
        return false;   // the resend once the reply lands
    };
    var h: [20]u8 = undefined;
    h[0] = 0x45;
    h[1] = 0;
    const tot: u16 = @intCast(20 + payload.len);
    h[2] = @intCast(tot >> 8);
    h[3] = @intCast(tot & 0xFF);
    h[4] = @intCast(ip_id >> 8);
    h[5] = @intCast(ip_id & 0xFF);
    ip_id +%= 1;
    h[6] = 0x40; // DF
    h[7] = 0;
    h[8] = 64; // TTL
    h[9] = proto;
    h[10] = 0;
    h[11] = 0;
    @memcpy(h[12..16], &MY_IP);
    @memcpy(h[16..20], &dst);
    const cs = csum(&h);
    h[10] = @intCast(cs >> 8);
    h[11] = @intCast(cs & 0xFF);
    var frame: [20 + 1600]u8 = undefined;
    @memcpy(frame[0..20], &h);
    @memcpy(frame[20 .. 20 + payload.len], payload);
    return ethTx(dmac, 0x0800, frame[0 .. 20 + payload.len]);
}

// ---- TCP client sessions ---------------------------------------------------

const TCP_FREE: u8 = 0;
const TCP_ARP: u8 = 1; // waiting on the neighbor resolve to send SYN
const TCP_SYN: u8 = 2;
const TCP_EST: u8 = 3;
const TCP_FINW: u8 = 4; // we FIN'd, waiting for peer ACK/FIN
const TCP_CLOSED: u8 = 5; // verdict landed — refused or torn down

const Tcp = struct {
    used: bool = false,
    pair: usize = 0, // the SockPair this session feeds
    state: u8 = TCP_FREE,
    rip: [4]u8 = .{0} ** 4,
    rport: u16 = 0,
    lport: u16 = 0,
    snd_una: u32 = 0,
    snd_nxt: u32 = 0,
    rcv_nxt: u32 = 0,
    fin_sent: bool = false,
    fin_acked: bool = false,
    peer_fin: bool = false,
    una_buf: [8192]u8 = undefined, // unacked payload, retransmit's copy
    una_len: usize = 0,
    retry_at: u64 = 0,
    retries: u8 = 0,
    cerr: u8 = 0,
};

const NSESS = 8;
var sess: [NSESS]Tcp = [_]Tcp{.{}} ** NSESS;
var lport_next: u16 = 49152;

pub const Hooks = struct {
    // returns bytes consumed — the un-acked tail retransmits, real
    // TCP backpressure instead of a silent drop
    rxData: *const fn (pair: usize, data: []const u8) usize,
    eof: *const fn (pair: usize) void,
    rst: *const fn (pair: usize) void,
    connDone: *const fn (pair: usize, errno: u8) void, // 0 = up
};
var hooks: Hooks = undefined;
var hooks_set: bool = false;
pub fn setHooks(h: Hooks) void {
    hooks = h;
    hooks_set = true;
}

fn segTx(t: *Tcp, flags: u8, payload: []const u8, seq: u32) bool {
    var h: [20]u8 = undefined;
    h[0] = @intCast(t.lport >> 8);
    h[1] = @intCast(t.lport & 0xFF);
    h[2] = @intCast(t.rport >> 8);
    h[3] = @intCast(t.rport & 0xFF);
    std.mem.writeInt(u32, h[4..8], seq, .big);
    std.mem.writeInt(u32, h[8..12], t.rcv_nxt, .big);
    h[12] = 5 << 4; // data offset — no options on non-SYN
    h[13] = flags;
    std.mem.writeInt(u16, h[14..16], 2048, .big); // wnd — sized to the pair ring
    h[16] = 0;
    h[17] = 0;
    h[18] = 0;
    h[19] = 0;
    var seg: [20 + 1600]u8 = undefined;
    @memcpy(seg[0..20], &h);
    @memcpy(seg[20 .. 20 + payload.len], payload);
    const n = 20 + payload.len;
    const cs = tcpCsum(MY_IP, t.rip, seg[0..n]);
    seg[16] = @intCast(cs >> 8);
    seg[17] = @intCast(cs & 0xFF);
    return ipTx(t.rip, 6, seg[0..n]);
}

fn synTx(t: *Tcp, seq: u32) bool {
    // SYN carries MSS in the option space — a second build path since
    // the data-offset differs
    var h: [24]u8 = undefined;
    h[0] = @intCast(t.lport >> 8);
    h[1] = @intCast(t.lport & 0xFF);
    h[2] = @intCast(t.rport >> 8);
    h[3] = @intCast(t.rport & 0xFF);
    std.mem.writeInt(u32, h[4..8], seq, .big);
    std.mem.writeInt(u32, h[8..12], 0, .big);
    h[12] = 6 << 4; // 24B — one 4B MSS option
    h[13] = 0x02;
    std.mem.writeInt(u16, h[14..16], 2048, .big); // wnd — the ring
    h[16] = 0;
    h[17] = 0;
    h[18] = 0;
    h[19] = 0;
    h[20] = 2;
    h[21] = 4;
    h[22] = 0x05;
    h[23] = 0xB4; // MSS 1460
    const cs = tcpCsum(MY_IP, t.rip, &h);
    h[16] = @intCast(cs >> 8);
    h[17] = @intCast(cs & 0xFF);
    return ipTx(t.rip, 6, &h);
}

var iss: u32 = 0x2B00_0000; // TSC-free iss — sequence space is ours

// tcpConnect: allocates a session and starts the handshake. Returns the
// session INDEX+1 (0 = table full) — s.nid's "0 means unnegotiated"
// contract holds. errno comes back through hooks.connDone.
pub fn tcpConnect(pair: usize, rip: [4]u8, rport: u16, tick: u64) u8 {
    for (&sess, 0..) |*t, i| {
        if (t.used) continue;
        t.* = .{
            .used = true,
            .pair = pair,
            .state = TCP_ARP,
            .rip = rip,
            .rport = rport,
            .lport = lport_next,
            .snd_una = iss,
            .snd_nxt = iss,
        };
        iss +%= 0x1234;
        lport_next +%= 1;
        t.retry_at = tick + 1; // first sweep sends SYN (or the ARP)
        return @intCast(i + 1);
    }
    return 0;
}

// tcpSend: stage payload into the session's unacked window and put it
// on the wire. Returns bytes CONSUMED — the pair ring keeps what
// didn't fit, the same backpressure the relay's txq gives.
pub fn tcpSend(sid: u8, data: []const u8, tick: u64) usize {
    if (sid == 0) return 0;
    const t = &sess[sid - 1];
    if (!t.used or t.state != TCP_EST) return 0;
    const room = t.una_buf.len - t.una_len;
    const n = @min(room, data.len);
    if (n == 0) return 0;
    // stage first: the bytes get seq numbers NOW — una_buf is always
    // exactly [snd_una, snd_nxt), so a wire-drop needs no special case:
    // the retransmit sweep resends the whole window from snd_una.
    const seq_at = t.snd_nxt;
    @memcpy(t.una_buf[t.una_len .. t.una_len + n], data[0..n]);
    t.una_len += n;
    t.snd_nxt +%= @intCast(n);
    _ = segTx(t, 0x18, data, seq_at); // PSH|ACK — best effort, the
    // sweep owns loss (slirp drops under load; the window resends)
    t.retry_at = tick + 20; // ~1.1s at 55ms ticks
    t.retries = 0;
    return n;
}

pub fn tcpShutdown(sid: u8, tick: u64) void {
    if (sid == 0) return;
    const t = &sess[sid - 1];
    if (!t.used or t.fin_sent) return;
    if (t.state == TCP_EST) {
        _ = segTx(t, 0x11, &.{}, t.snd_nxt); // FIN|ACK
        t.snd_nxt +%= 1;
        t.fin_sent = true;
        t.state = TCP_FINW;
        t.retry_at = tick + 20;
    }
}

pub fn tcpClose(sid: u8) void {
    if (sid == 0) return;
    const t = &sess[sid - 1];
    if (!t.used) return;
    t.* = .{}; // the wire side dies with the pair — TIME_WAIT is a
               // named gap, not a protocol we fake
}

pub fn tcpState(sid: u8) u8 {
    if (sid == 0) return TCP_FREE;
    const t = &sess[sid - 1];
    if (!t.used) return TCP_FREE;
    return t.state;
}
pub fn tcpErrno(sid: u8) u8 {
    if (sid == 0) return 0;
    return sess[sid - 1].cerr;
}

// ---- rx demux ----------------------------------------------------------------

fn tcpRx(t: *Tcp, ip: []const u8, seg: []const u8) void {
    const seq = rd32(seg[4..8]);
    const ack = rd32(seg[8..12]);
    const doff: usize = @intCast(seg[12] >> 4);
    const flags = seg[13];
    const payload = seg[@max(doff * 4, 20)..];
    const SYN = (flags & 0x02) != 0;
    const ACK = (flags & 0x10) != 0;
    const RST = (flags & 0x04) != 0;
    const FIN = (flags & 0x01) != 0;
    _ = ip;

    if (RST) {
        t.cerr = if (t.state == TCP_SYN) 111 else 104; // REFUSED/RESET
        t.state = TCP_CLOSED;
        if (hooks_set) hooks.rst(t.pair);
        return;
    }
    switch (t.state) {
        TCP_SYN => {
            if (SYN and ACK and ack == t.snd_una +% 1) {
                t.snd_una = ack; // iss+1 — the SYN consumed a sequence
                t.snd_nxt = t.snd_una;
                t.rcv_nxt = seq +% 1;
                t.state = TCP_EST;
                _ = segTx(t, 0x10, &.{}, t.snd_nxt); // bare ACK
                if (hooks_set) hooks.connDone(t.pair, 0);
            }
        },
        TCP_EST, TCP_FINW => {
            if (ACK) {
                const adv = ack -% t.snd_una;
                // forward progress only — a stale/dup ACK can't walk
                // the window backward or past what we sent
                if (adv != 0 and adv <= t.una_len + @intFromBool(t.fin_sent)) {
                    t.snd_una = ack;
                    const drop = @min(t.una_len, @as(usize, @intCast(
                        if (t.fin_sent) adv -% 1 else adv)));
                    t.una_len -= drop;
                    std.mem.copyForwards(u8, t.una_buf[0..t.una_len],
                        t.una_buf[drop .. drop + t.una_len]);
                    if (t.fin_sent) t.fin_acked = true;
                    t.retries = 0;
                }
            }
            if (payload.len != 0 and seq == t.rcv_nxt) {
                // ack only what the pair ring accepted — the rest is a
                // retransmit into a drained ring, not a drop
                const n = if (hooks_set) hooks.rxData(t.pair, payload) else 0;
                t.rcv_nxt +%= @intCast(n);
                _ = segTx(t, 0x10, &.{}, t.snd_nxt); // immediate ACK
            } else if (payload.len != 0) {
                _ = segTx(t, 0x10, &.{}, t.snd_nxt); // out-of-order:
                    // dup-ACK the last contiguous — reassembly is a gap
            }
            if (FIN and seq +% @as(u32, @intCast(payload.len)) == t.rcv_nxt) {
                t.rcv_nxt +%= 1;
                t.peer_fin = true;
                _ = segTx(t, 0x10, &.{}, t.snd_nxt);
                if (hooks_set) hooks.eof(t.pair);
            }
            if (t.state == TCP_FINW and t.fin_acked and t.peer_fin)
                t.state = TCP_CLOSED;
        },
        else => {},
    }
}

fn icmpRx(src: [4]u8, ip: []const u8, msg: []const u8) void {
    if (msg.len < 8 or msg.len > 1500) return;
    if (msg[0] == 0 and echo_pending > 0) {
        echo_pending -= 1;
        ping_seen += 1;
        koru_say("net: icmp echo reply from ");
        koru_putdec(src[0]);
        koru_say(".");
        koru_putdec(src[1]);
        koru_say(".");
        koru_putdec(src[2]);
        koru_say(".");
        koru_putdec(src[3]);
        koru_say("\n");
        return;
    }
    if (msg[0] != 8) return; // echo request only
    var rep: [1600]u8 = undefined;
    @memcpy(rep[0..msg.len], msg);
    rep[0] = 0; // reply
    rep[2] = 0;
    rep[3] = 0;
    const cs = csum(rep[0..msg.len]);
    rep[2] = @intCast(cs >> 8);
    rep[3] = @intCast(cs & 0xFF);
    _ = ipTx(src, 1, rep[0..msg.len]);
    _ = ip;
}

fn ipRx(frame: []const u8) void {
    if (frame.len < 20 or (frame[0] >> 4) != 4) return;
    const ihl: usize = @intCast((frame[0] & 0x0F) * 4);
    const proto = frame[9];
    const src = frame[12..16].*;
    const dst = frame[16..20].*;
    if (!std.mem.eql(u8, &dst, &MY_IP)) return; // slirp broadcasts —
        // only our address is ours
    // the IP total length bounds the body — short frames carry eth
    // padding that would otherwise read as trailing TCP payload and
    // walk rcv_nxt past real sequence numbers
    const tot: usize = @intCast(rd16(frame[2..4]));
    if (tot < ihl or tot > frame.len) return;
    const body = frame[ihl..tot];
    switch (proto) {
        1 => icmpRx(src, frame, body),
        6 => { // TCP — find the session by lport
            if (body.len < 20) return;
            const dport = rd16(body[2..4]);
            for (&sess) |*t| {
                if (t.used and t.lport == dport) {
                    tcpRx(t, frame, body);
                    return;
                }
            }
        },
        else => {},
    }
}

fn ethRx(frame: []const u8) void {
    if (frame.len < 14) return;
    const etype = (@as(u16, frame[12]) << 8) | frame[13];
    switch (etype) {
        0x0806 => { // ARP
            const p = frame[14..];
            if (p.len < 28) return;
            const op = rd16(p[6..8]);
            if (op == 1 and std.mem.eql(u8, p[24..28], &MY_IP)) {
                // request for us — learn + reply
                arpLearn(p[14..18].*, p[8..14].*);
                var rep: [28]u8 = undefined;
                @memcpy(rep[0..28], p[0..28]);
                rep[7] = 2; // reply
                @memcpy(rep[8..14], &my_mac);
                @memcpy(rep[14..18], &MY_IP);
                @memcpy(rep[18..24], p[8..14]);
                @memcpy(rep[24..28], p[14..18]);
                var dmac: [6]u8 = undefined;
                @memcpy(&dmac, p[8..14]);
                _ = ethTx(dmac, 0x0806, &rep);
            } else if (op == 2) {
                arpLearn(p[14..18].*, p[8..14].*);
            }
        },
        0x0800 => ipRx(frame[14..]),
        else => {},
    }
}

// ---- the engine tick -----------------------------------------------------------

// stackPoll: drain the rx used-ring into the stack, reap tx, run the
// retransmit sweep. Rides the IRQ door and the 55ms tick — RTT-scale
// granularity is fine for slirp's LAN.
pub fn stackPoll(tick: u64) void {
    if (!armed) return;
    last_tick = tick;
    // rx drain
    while (rxq.last_used != rxq.used_idx.*) {
        const e = rxq.used_ring[rxq.last_used % NRX];
        const buf = &rxbuf[e.id];
        // virtio hdr is 12B under VERSION_1 (no MRG_RXBUF negotiated)
        const flen: usize = @intCast(e.len);
        if (flen > 12) ethRx(buf[12..flen]);
        // repost the same buffer
        rxq.descs[e.id].len = 2048;
        const ai = rxq.avail_idx.*;
        rxq.avail_ring[ai % NRX] = @intCast(e.id);
        rxq.avail_idx.* = ai + 1;
        rxq.last_used +%= 1;
    }
    vp.kick(&dev, &rxq);
    txReap();
    // session sweep — SYN sends (after ARP lands), retransmits, closes
    for (&sess) |*t| {
        if (!t.used) continue;
        switch (t.state) {
            TCP_ARP => {
                if (tick >= t.retry_at) {
                    const nh = neighborFor(t.rip);
                    if (arpFind(nh) != null) {
                        _ = synTx(t, t.snd_nxt);
                        t.state = TCP_SYN;
                        t.retry_at = tick + 20;
                        t.retries = 0;
                    } else {
                        arpRequest(nh);
                        t.retry_at = tick + 10;
                        t.retries += 1;
                        if (t.retries > 8) {
                            t.cerr = 113; // EHOSTUNREACH — no ARP answer
                            t.state = TCP_CLOSED;
                            if (hooks_set) hooks.connDone(t.pair, 113);
                        }
                    }
                }
            },
            TCP_SYN => {
                if (tick >= t.retry_at) {
                    t.retries += 1;
                    if (t.retries > 5) {
                        t.cerr = 110; // ETIMEDOUT
                        t.state = TCP_CLOSED;
                        if (hooks_set) hooks.connDone(t.pair, 110);
                    } else {
                        _ = synTx(t, t.snd_una);
                        t.retry_at = tick + 20;
                    }
                }
            },
            TCP_EST, TCP_FINW => {
                if (tick >= t.retry_at) {
                    if (t.fin_sent and !t.fin_acked) {
                        _ = segTx(t, 0x11, &.{}, t.snd_una +%
                            @as(u32, @intCast(t.una_len)));
                    } else if (t.una_len > 0) {
                        // resend the whole unacked window as one seg
                        _ = segTx(t, 0x18, t.una_buf[0..t.una_len],
                            t.snd_una);
                    }
                    t.retries += 1;
                    if (t.retries > 8) {
                        t.cerr = 110;
                        t.state = TCP_CLOSED;
                        if (hooks_set) hooks.rst(t.pair);
                    } else {
                        t.retry_at = tick + 40; // ~2.2s backoff-ish
                    }
                }
            },
            else => {},
        }
    }
    // ping retry — a pre-ARP echo lands in ipTx's drop path; resend on
    // the same sweep the TCP retries ride
    // ping retry fallback for non-ARP drops — the boot epoch's tick
    // budget is only ~6 ticks, so the window is short and the real
    // resend trigger lives in arpLearn
    if (echo_pending > 0 and tick >= echo_at + 3 and echo_retries < 6) {
        echo_retries += 1;
        echo_at = tick;
        echoTx();
    }
}

// icmpEcho: the ping evidence — seq rides the payload id, a marker
// prints when the reply comes back through icmpRx... kept simple:
// the oracle's ping is host->guest? No — guest->gw. Slirp answers.
var echo_pending: u8 = 0;
var echo_ip: [4]u8 = .{0} ** 4;
var echo_at: u64 = 0;
var echo_retries: u8 = 0;
var last_tick: u64 = 0;

fn echoTx() void {
    var m: [16]u8 = undefined;
    m[0] = 8; // echo request
    m[1] = 0;
    m[2] = 0;
    m[3] = 0;
    m[4] = 0;
    m[5] = 1;
    m[6] = 0;
    m[7] = 1;
    @memset(m[8..], 0xAA);
    const cs = csum(&m);
    m[2] = @intCast(cs >> 8);
    m[3] = @intCast(cs & 0xFF);
    _ = ipTx(echo_ip, 1, &m);
}

pub fn icmpEcho(ip: [4]u8) void {
    echo_ip = ip;
    echo_pending += 1;
    echo_retries = 0;
    echo_at = last_tick;
    echoTx();
}

// init: arm the device, then prime the wire — an ARP for the gateway
// so the first connect isn't ARP-blocked, plus the boot marker.
pub fn devProbe() void {
    if (!devInit()) return; // silent-absent like the COM2 probe
    koru_say("net: stack up — ip 10.0.2.15 gw 10.0.2.2 (static, slirp)\n");
}

const std = @import("std");
