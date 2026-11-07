// koru/native net — stage-marker telemetry: Ethernet + IPv4 + UDP, TX-only.
//
// Design (commission session/net-telemetry-BRIEF.md): the display is dead
// during i915 bring-up and every local-output channel is gone, so the
// kernel phones home instead. UDP is stateless fire-and-forget — one
// datagram per stage marker, no handshake, no retransmit, no RX path.
//
// TX-only consequence, stated plainly: we cannot resolve ARP (no replies
// arrive), so frames go to the BROADCAST MAC carrying a UNICAST IP
// datagram. Every host on the L2 segment gets the frame; only the IP
// owner accepts it at L3 — the Mac's listener sees exactly our packets
// and nothing else on the LAN does. An ARP request is still emitted at
// init (N1 wire proof — visible in any listener's tcpdump).
//
// Destination (coordinated with orchestrator t1, 2026-11-07):
//   src 192.168.1.222 -> dst 192.168.1.5 udp/47820, payload "KORU <stage>"

const std = @import("std");
const e1000e = @import("e1000e");
const pci = @import("pci");

extern fn koru_say(s: [*:0]const u8) void;
fn say(s: [*:0]const u8) void {
    koru_say(s);
}
fn sayf(comptime f: []const u8, a: anytype) void {
    var b: [192]u8 = undefined;
    const s = std.fmt.bufPrintZ(&b, f ++ "\n", a) catch return;
    say(s.ptr);
}

// ---- link config ------------------------------------------------------------

// Destination (coordinated with orchestrator t1): P2P link Mac en8
// (USB GbE) 192.168.99.1/24 <-> ThinkPad 192.168.99.2, static both ends.
const OUR_IP: [4]u8 = .{ 192, 168, 99, 2 };
const DST_IP: [4]u8 = .{ 192, 168, 99, 1 };
const DST_PORT: u16 = 47820;
const SRC_PORT: u16 = 47821;
const BCAST_MAC: [6]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

var up: bool = false;
var tx_seq: u16 = 0;

// staging — one frame at a time is fine: markers are rare and e1000e.tx
// polls the slot's DD bit before the ring wraps.
var frame: [2048]u8 align(64) = undefined;

fn csum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while (sum >> 16 != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @intCast(~sum & 0xFFFF);
}

fn put16(b: []u8, off: usize, v: u16) void {
    b[off] = @truncate(v >> 8);
    b[off + 1] = @truncate(v);
}
fn put32(b: []u8, off: usize, v: u32) void {
    b[off] = @truncate(v >> 24);
    b[off + 1] = @truncate(v >> 16);
    b[off + 2] = @truncate(v >> 8);
    b[off + 3] = @truncate(v);
}

// ethSend: dst/src MAC + ethertype already meaningful per caller via
// `etype`; frame body starts at offset 14.
fn ethHdr(etype: u16) usize {
    const mac = e1000e.macAddr();
    @memcpy(frame[0..6], &BCAST_MAC);
    @memcpy(frame[6..12], mac);
    put16(frame[0..], 12, etype);
    return 14;
}

// arpAnnounce: who-has DST_IP tell OUR_IP — N1 wire proof; a listener's
// tcpdump sees it even though we can never hear the reply.
fn arpAnnounce() bool {
    const o = ethHdr(0x0806);
    const p = o;
    frame[p + 0] = 0; frame[p + 1] = 1; // htype ethernet
    frame[p + 2] = 0x08; frame[p + 3] = 0x00; // ptype ipv4
    frame[p + 4] = 6; frame[p + 5] = 4; // hlen/plen
    put16(frame[0..], p + 6, 1); // oper request
    const mac = e1000e.macAddr();
    @memcpy(frame[p + 8..p + 14], mac); // sha
    @memcpy(frame[p + 14..p + 18], &OUR_IP); // spa
    @memset(frame[p + 18..p + 24], 0); // tha
    @memcpy(frame[p + 24..p + 28], &DST_IP); // tpa
    return e1000e.tx(frame[0 .. p + 28]);
}

// udpSendTo: payload -> UDP/IPv4/Ethernet-broadcast -> wire, arbitrary
// destination IP/port (shell 'udp' command uses this for live probes).
fn udpSendTo(dst_ip: [4]u8, dst_port: u16, payload: []const u8, probe: bool) bool {
    if (payload.len > 400) {
        sayf("net: marker too long ({d}B) — refused", .{payload.len});
        return false;
    }
    const o = ethHdr(0x0800);
    const ip = o;
    const udp = ip + 20;
    const pay = udp + 8;
    const iplen: u16 = @intCast(28 + payload.len);
    const udplen: u16 = @intCast(8 + payload.len);

    // IPv4 header
    frame[ip + 0] = 0x45; // v4, ihl 5
    frame[ip + 1] = 0;
    put16(frame[0..], ip + 2, iplen);
    tx_seq +%= 1;
    put16(frame[0..], ip + 4, tx_seq);
    put16(frame[0..], ip + 6, 0x4000); // DF
    frame[ip + 8] = 64; // ttl
    frame[ip + 9] = 17; // udp
    put16(frame[0..], ip + 10, 0); // csum placeholder
    @memcpy(frame[ip + 12..ip + 16], &OUR_IP);
    @memcpy(frame[ip + 16..ip + 20], &dst_ip);
    put16(frame[0..], ip + 10, csum(frame[ip .. ip + 20]));

    // UDP header
    put16(frame[0..], udp + 0, SRC_PORT);
    put16(frame[0..], udp + 2, dst_port);
    put16(frame[0..], udp + 4, udplen);
    put16(frame[0..], udp + 6, 0); // csum placeholder
    @memcpy(frame[pay .. pay + payload.len], payload);

    // UDP checksum over pseudo-header + segment (mandatory to compute —
    // zero is legal for IPv4 but a real sum costs nothing and keeps
    // every middlebox honest).
    var pseudo: [420]u8 = undefined;
    @memcpy(pseudo[0..4], &OUR_IP);
    @memcpy(pseudo[4..8], &dst_ip);
    pseudo[8] = 0;
    pseudo[9] = 17;
    put16(pseudo[0..], 10, udplen);
    @memcpy(pseudo[12 .. 12 + udplen], frame[udp .. udp + udplen]);
    const ucs = csum(pseudo[0 .. 12 + udplen]);
    put16(frame[0..], udp + 6, if (ucs == 0) 0xFFFF else ucs);

    const f = frame[0 .. pay + payload.len];
    if (probe) return e1000e.txProbe(f, 200 * 1_000_000);
    return e1000e.tx(f);
}

fn udpSend(payload: []const u8) bool {
    return udpSendTo(DST_IP, DST_PORT, payload, false);
}

// ---- shell-facing surface ----------------------------------------------------

pub const Status = struct {
    active: bool,
    link: bool,
    live_status: u32,
    mac: ?*const [6]u8,
    our_ip: [4]u8,
    dst_ip: [4]u8,
    dst_port: u16,
    diag: e1000e.Diag,
    stats: e1000e.Stats,
    last_probe_ok: bool,
};

pub fn status() Status {
    return .{
        .active = up,
        .link = e1000e.linkIsUp(),
        .live_status = e1000e.liveStatus(),
        .mac = if (up) e1000e.macAddr() else null,
        .our_ip = OUR_IP,
        .dst_ip = DST_IP,
        .dst_port = DST_PORT,
        .diag = e1000e.diagInfo(),
        .stats = e1000e.stats(),
        .last_probe_ok = e1000e.lastTxWaitOk(),
    };
}

// sendUdp: arbitrary datagram for the shell 'udp' command — synchronous
// DD probe so the shell can say whether the DESCRIPTOR completed (the
// only TX oracle without RX), not just that we queued it.
pub fn sendUdp(ip: [4]u8, port: u16, msg: []const u8) bool {
    if (!up) return false;
    return udpSendTo(ip, port, msg, true);
}

// mark: emit one "KORU <tag>" datagram. tag is a comptime string.
pub fn mark(comptime tag: []const u8) void {
    if (!up) return;
    var msg: [448]u8 = undefined;
    const s = std.fmt.bufPrint(&msg, "KORU {s}", .{tag}) catch return;
    if (udpSend(s)) {
        sayf("net: -> {s}", .{s});
    } else {
        sayf("net: TX FAILED {s}", .{s});
    }
}

// init: PCI table must already be scanned (pci.init is idempotent —
// boot.zig calls it on the fullBoot path; we call it here on the
// console path so telemetry works with display dead).
pub fn init() void {
    if (pci.count == 0) pci.init();
    if (!e1000e.init()) {
        say("net: NIC init failed — telemetry down, boot continues\n");
        return;
    }
    up = true;
    sayf("net: telemetry up — {d}.{d}.{d}.{d}:{d} <- src {d}.{d}.{d}.{d}", .{
        DST_IP[0], DST_IP[1], DST_IP[2], DST_IP[3], DST_PORT,
        OUR_IP[0], OUR_IP[1], OUR_IP[2], OUR_IP[3],
    });
    if (arpAnnounce()) say("net: N1 arp who-has on wire\n") else say("net: N1 arp TX FAILED\n");

    // diag marker — encode what init actually did so the listener log
    // carries the state even when later stages die. Fields: stage reached,
    // bar phys, pci cmd, status reg, tctl, ring regs, mac source, link.
    {
        const d = e1000e.diagInfo();
        const mac = e1000e.macAddr();
        var msg: [440]u8 = undefined;
        const s = std.fmt.bufPrint(&msg, "KORU diag st={d} bar={x} cmd={x} st={x} tctl={x} bal={x} len={x} dt={x} mac={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} msrc={d} link={s}", .{
            d.stage, d.bar0, d.cmd, d.status, d.tctl,
            d.td_bal, d.td_len, d.td_t,
            mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
            d.mac_src, if (e1000e.linkIsUp()) "1" else "0",
        }) catch return;
        _ = udpSend(s);
        sayf("net: diag -> {s}", .{s});
    }
    mark("N2 udp telemetry live");
}
