#!/usr/bin/env python3
# koru net-telemetry UDP listener — logs every datagram to listener.log
# and stdout. Bound 0.0.0.0:47820 so wired+wifi delivery both land.
import socket, sys, datetime
port = int(sys.argv[1]) if len(sys.argv) > 1 else 47820
log = open('/Users/larsde/src/koru-os-net/session/net-telemetry/listener.log', 'a', buffering=1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('0.0.0.0', port))
print(f'listening udp/{port}', flush=True)
while True:
    data, addr = s.recvfrom(4096)
    ts = datetime.datetime.now().isoformat(timespec='milliseconds')
    line = f'{ts} {addr[0]}:{addr[1]} len={len(data)} {data!r}'
    print(line, flush=True)
    log.write(line + '\n')
