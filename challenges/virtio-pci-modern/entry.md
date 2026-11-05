---
name: virtio-pci-modern
iface: koruos/virtio.pci
arms: [koru-native]
lane: native-zig
needs: [pci-enumeration]
accept: VERSION_1 device driven through capability-list transport
tier: qemu
status: open
evidence: —
peer: koru-desktop/providers/virtio-pci-modern
provenance: partially landed — virtiopci.zig is legacy/transitional
---

# virtio-pci-modern

virtio-1.0 transport: common/isr/device/notify config capabilities off
the PCI cap list, feature negotiation, virtqueue setup through the
modern registers — instead of the legacy I/O-port layout the current
provider speaks.

## Acceptance

`-device virtio-*-pci` (non-transitional, `disable-legacy=on`): the
provider negotiates through modern caps and the device works — no
legacy I/O port traffic.

## Notes

- Existing virtio stack is legacy+transitional; this unlocks the
  modern-only device shapes QEMU increasingly defaults toward.
- Shared slot with koru-desktop (their lane is donor-c for the
  unikraft arm) — ours is the kernel-level twin.
