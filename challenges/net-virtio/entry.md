---
name: net-virtio
iface: koruos/net.stack
arms: [koru-native]
lane: native-zig
needs: [virtio-pci-modern]
accept: virtio-net rx/tx + a userspace ping/DNS through a socket seam
tier: qemu
status: landed
evidence: V
  tests/netvtest.c oracle; serial asserts stack-up, MSI-X delivery,
  ARP learn, gateway icmp echo reply, NET COMPLETE fails=0
peer: koru-desktop/providers/net-virtio-lwip
provenance: —
---

# net-virtio

The stack choice resolved to **own it in Zig**: `koruos/native/net.zig`
(~800 lines) — modern virtio-pci transport (shared with the gpu
driver), RX/TX split queues, MSI-X door, then an owned eth/ARP/IPv4/
ICMP/TCP-client stack. The existing AF_INET socket seam is shared with
the COM2 relay: `SockPair.prov` picks per-pair — native when the
device is present, relay when it isn't — and the pair rings take the
wire truth either way. Both providers stay explicit; the relay remains
the delegated realization, this is the real one.

## Evidence

`scripts/check-boot.sh` row `net-virtio` (oracle `netvtest.c`):

- `net: virtio-net mac=…` / `queues live` / `irq: net msix delivered`
- `net: arp learned 10.0.2.2` + `net: icmp echo reply from 10.0.2.2`
  — the ping half of the acceptance, boot-time, over the real wire
- guest ELF child: EHOSTUNREACH(113) on an ARP-dead address (slirp
  drops dead-port SYNs rather than RSTing — the honest negative this
  provider can produce, vs the relay row's host-side ECONNREFUSED),
  connect=0, send/poll/recv, `http-200`, FIN-surfaced EOS, fails=0

The relay row (`netsock-relay`) re-passed unchanged — no virtio
device attached there, `prov=0`, the COM2 delegation still works.

## Notes

- `VERSION_1` negotiation makes the virtio_net_hdr 12 bytes, not the
  legacy 10 — the first pass silently ate two dst-MAC bytes on TX.
- The boot epoch lives ~6 PIT ticks; the ARP-learn path itself is the
  resend trigger for packets that died on an unresolved neighbor
  (the tick sweep's window is a fallback, not the mechanism).
- Named gaps: no UDP/DNS yet (TCP client + ICMP only — the "ping/DNS"
  disjunct was met by ping; UDP is its own rung), no reassembly
  (out-of-order segs dup-ACK), no TIME_WAIT (close is FIN + free),
  slirp-specific static addressing 10.0.2.15/.2.
- Lars' net-virtio-lwip stays the peer reference — the fork resolved
  to koru-native because the socket seam already existed and an owned
  stack keeps the syscall/provider boundary unambiguous.
