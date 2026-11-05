---
name: hw-tier-validation
iface: koruos/oracle.hw
arms: [koru-native]
lane: oracle
needs: [usb-xhci, usb-hid]
accept: usb-esp image dd'd to a real stick boots a real machine to a marker
tier: hw
status: open
evidence: —
peer: —
provenance: —
---

# hw-tier-validation

Real hardware boot: the usb-esp image dd'd to a physical stick, booted
on a real machine (ThinkPad-class, UEFI, Secure Boot off), reaching a
known-good serial/GOP marker. Every qemu row so far is emulation; this
is the tier boundary.

## Acceptance

Photo/serial log evidence: BdsDxe-class boot -> GRUB-EFI -> mb2 ->
kernel banner -> initramfs child output, on named real hardware.
Repeated on a second machine to catch quirk-class failures.

## Notes

- Usable-on-desk (kbd input + persistence) needs usb-xhci+usb-hid+
  usb-storage — boot-proof alone is achievable today.
- Secure Boot is unsigned BOOTX64.EFI — off, or the shim rung.
- GOP framebuffer varies; mb2 fb request may come back 1024x768.
