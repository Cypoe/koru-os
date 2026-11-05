---
name: usb-xhci
iface: koruos/usb.host
arms: [koru-native]
lane: native-zig
needs: [pci-enumeration, irq-msix]
accept: qemu-xhci enumerates usb-kbd/usb-storage — slot ids + descriptors on serial
tier: qemu
status: open
evidence: —
peer: koru-desktop/providers/usb-xhci
provenance: xhci 1.0/1.2 spec + QEMU model; NONOS capsule is AGPL — read-only
---

# usb-xhci

xHCI host controller: command/event/transfer rings, slot+endpoint
contexts, port enumeration. Root of the USB subtree — hid and storage
both sit on it. This is the rung that makes the flash stick usable
*after* boot and a real keyboard work on real hardware.

## Acceptance

`-device qemu-xhci -device usb-kbd -device usb-storage,drive=x`:
host reset, CRCR/DCBAAP, port scan, slot alloc, device descriptors on
serial (VID:PID 0627:0001). Falsifiable: empty controller enumerates
zero slots without a fault.

## Notes

- Lars' parallel slot landed tier qemu (their unikraft arm) — the
  register-level facts transfer; the driver itself is ours.
- koru-desktop's census: NONOS xhci is AGPL-3.0+ — orientation only,
  never derive. xhci-nostd (Apache-2.0) is the clean prior-art read.
- hw tier needs quirk handling (Renesas/ASMedia/Intel) — keep the
  register layer absorbable.
