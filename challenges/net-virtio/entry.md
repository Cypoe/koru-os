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

- Lars' catalog has net-virtio-lwip landed (compose lane) — their
  lwIP integration facts transfer; whether the kernel borrows the
  stack or owns it is a genuine fork to decide at start.
- No socket ABI exists yet — AF_INET endpoints need an FdKind +
  the poll/epoll wiring pipes/socks already set the shape for.
