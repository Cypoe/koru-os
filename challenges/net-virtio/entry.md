---
name: net-virtio
iface: koruos/net.stack
arms: [koru-native]
lane: native-zig
needs: [virtio-pci-modern]
accept: virtio-net rx/tx + a userspace ping/DNS through a socket seam
tier: qemu
status: open
evidence: —
peer: koru-desktop/providers/net-virtio-lwip
provenance: —
---

# net-virtio

virtio-net device (rx/tx virtqueues) plus a real socket layer for
children — currently zero networking exists. The question underneath
is stack choice: port lwIP (donor-c) vs koru-native stack.

## Acceptance

`-netdev user -device virtio-net-pci`: rx/tx queues up, ARP+ICMP
through, and a child does a real socket connect/DNS resolve through
whatever stack the entry lands.

## Notes

- Lars' rig landed net-virtio-lwip with HOST-VERIFIED evidence
  (efff0b3): Unikraft booted on bare metal, lwip init -> IPv4
  10.0.2.15 on user-net -> connect -> recv rc=0, and the host
  listener saw "guest-says-hi". The virtio-net + lwip shape is
  proven; whether we borrow the stack or own it is still the fork.
- No socket ABI exists yet — AF_INET endpoints need an FdKind +
  the poll/epoll wiring pipes/socks already set the shape for.
