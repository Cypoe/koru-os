---
name: pci-enumeration
iface: koruos/pci
arms: [koru-native]
lane: native-zig
needs: []
accept: gate row pci-enum — i440FX table printed on serial
tier: qemu
status: landed
evidence: M
peer: koru-desktop/providers/pci-enumeration
provenance: original — i440fx CF8/CFB config-space walk, one-shot table
---

# pci-enumeration

Legacy CF8 config-cycle enumeration of the PCI bus — the table every
bus-bound provider consumes (virtio-blk resolved off it, gpu caps walk,
MSI-X capability scan).

## Acceptance

Gate row `pci-enum`: serial shows the i440FX set by name (host bridge,
multifunction PIIX3, VGA, NIC); `pci-enum` also proves virtio-blk
resolution + MSI-X cap walk. Tier hw open: ECAM for PCIe host bridges.

## Notes

- ECAM (PCIe enhanced config) is the hw-tier variant — Q35/QEMU supports
  it today; real hardware requires it beyond bus 0.
