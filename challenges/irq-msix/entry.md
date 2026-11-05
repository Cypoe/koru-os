---
name: irq-msix
iface: koruos/irq
arms: [koru-native]
lane: native-zig
needs: [pci-enumeration]
accept: gate row vgpu-msix — MSI-X vector dispatched through LAPIC EOI
tier: qemu
status: landed
evidence: M
peer: koru-desktop/providers/irq-msix
provenance: original — MSI-X table walk, vectors 0x30+, EOI to 0xFEE000B0
---

# irq-msix

MSI-X delivery through the IOAPIC/LAPIC door: capability walk finds the
table, vectors program to 0x30+, EOI writes to the LAPIC — the PIC is
masked and stays masked.

## Acceptance

Gate row `vgpu-msix`: a real MSI-X interrupt count measured through the
virtio-gpu device — not a simulated delivery.

## Notes

- Per-CPU IOREDTBL destinations are a follow-on (see smp-multirunner).
