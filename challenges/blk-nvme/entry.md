---
name: blk-nvme
iface: koruos/blk.nvme
arms: [koru-native]
lane: native-zig
needs: [pci-enumeration, irq-msix]
accept: admin+io queues up, identify, read LBA 0 of a QEMU nvme device
tier: qemu
status: open
evidence: —
peer: koru-desktop/providers/blk-nvme
provenance: —
---

# blk-nvme

NVMe controller: BAR-mapped admin+IO submission/completion queue pairs,
identify controller/namespace, READ commands. The storage a ThinkPad
actually has — the real-hardware persistence rung alongside
usb-storage.

## Acceptance

`-device nvme,drive=x`: admin queue handshake (CSTS.EN, AQA/ASQ/ACQ),
IDENTIFY, create IO queues, read LBA 0, compare against known image
bytes.

## Notes

- MSI-X preferred door already exists (irq-msix landed).
- Namespace + flush commands for the write path — persistence milestone.
