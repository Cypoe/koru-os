#!/usr/bin/env python3
"""pcap2wire — turn a QEMU filter-dump pcap into listener.log-format lines.

QEMU user-net (slirp) drops subnet-directed broadcasts (192.168.99.255),
which is exactly what koru-native telemetry uses (udpSendBc). On the real
T590 P2P link broadcasts arrive fine; under slirp only unicast probes do.
-qemu-arg: -object filter-dump,id=d0,netdev=n0,file=out.pcap captures every
frame the guest NIC emits BEFORE slirp drops it. This script extracts each
IPv4/UDP payload and emits one listener.log-style line per datagram, so
gate-surf-wire.py / gate-perf-wire.py consume QEMU runs unchanged.

Usage: pcap2wire.py <in.pcap> [out.log]   (stdout when out omitted)
"""
import sys, struct, datetime


def parse_pcap(path):
    data = open(path, "rb").read()
    if len(data) < 24:
        return
    magic = data[:4]
    if magic == b"\xd4\xc3\xb2\xa1":      # usec, little-endian
        en = "<"
    elif magic == b"\xa1\xb2\xc3\xd4":    # usec, big-endian
        en = ">"
    else:
        print(f"pcap2wire: bad magic {magic.hex()}", file=sys.stderr)
        return
    off = 24
    while off + 16 <= len(data):
        ts_s, ts_u, incl, _orig = struct.unpack(en + "IIII", data[off:off + 16])
        off += 16
        frame = data[off:off + incl]
        off += incl
        r = udp_payload(frame)
        if r is None:
            continue
        sport, dport, payload = r
        ts = datetime.datetime.fromtimestamp(ts_s + ts_u / 1e6).isoformat(timespec="milliseconds")
        yield ts, sport, dport, payload


def udp_payload(f):
    """Ethernet frame -> (sport, dport, payload) for IPv4/UDP, else None."""
    if len(f) < 14 + 20 + 8 or f[12:14] != b"\x08\x00":
        return None
    ip = f[14:]
    if ip[0] >> 4 != 4 or ip[9] != 17:
        return None
    ihl = (ip[0] & 0x0F) * 4
    if ihl < 20:
        return None
    udp = ip[ihl:]
    if len(udp) < 8:
        return None
    ulen = struct.unpack(">H", udp[4:6])[0]
    if ulen < 8 or ihl + ulen > len(ip):
        return None
    sport, dport = struct.unpack(">HH", udp[0:4])
    return sport, dport, udp[8:ulen]


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[-1]); return 2
    out = open(sys.argv[2], "w") if len(sys.argv) > 2 else sys.stdout
    n = 0
    for ts, sport, dport, payload in parse_pcap(sys.argv[1]):
        line = f"{ts} qemu:{sport}->{dport} len={len(payload)} {payload!r}\n"
        out.write(line)
        n += 1
    if len(sys.argv) > 2:
        out.close()
        print(f"pcap2wire: {n} datagrams -> {sys.argv[2]}", file=sys.stderr)
    else:
        print(f"pcap2wire: {n} datagrams", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
