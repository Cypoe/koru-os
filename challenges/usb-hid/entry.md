---
name: usb-hid
iface: koruos/input.usb
arms: [koru-native]
lane: native-zig
needs: [usb-xhci]
accept: usb-kbd scancodes + usb-tablet positions arrive via interrupt IN
tier: qemu
status: open
evidence: —
peer: koru-desktop/providers/usb-hid
provenance: —
---

# usb-hid

HID over interrupt pipes: report descriptors, boot-protocol keyboard
scancodes and tablet absolute positions, translated into the same
input-event seam PS/2 feeds today.

## Acceptance

`-device usb-kbd -device usb-tablet` behind qemu-xhci: monitor-injected
key/tablet events arrive as input facts through the same seam the
input-kbd/input-mouse rows already assert.

## Notes

- Boot protocol first (no descriptor parsing needed) — report
  descriptor parsing is the follow-on.
