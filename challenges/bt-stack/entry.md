---
name: bt-stack
iface: koruos/bt.hci
arms: [koru-native]
lane: native-zig
needs: [usb-xhci]
accept: a USB bluetooth dongle answers an HCI inquiry — far-future, file for the ledger
tier: hw
status: open
evidence: —
peer: koru-desktop lists bluetooth in its provider catalog
provenance: —
---

# bt-stack

Bluetooth via USB HCI: dongle enumeration, HCI commands, then the
real stack (L2CAP/HID/audio profiles). Filed to name the gap — the
voice-remote idea (Siri remote as a capability input) lands here
eventually.

## Acceptance

On the hw tier: an HCI inquiry returns names/addresses off a real
dongle. Everything past that is a later catalog entry.

## Notes

- Rides usb-xhci first (the dongle enumerates there); HID profile
  ties it to the input rung.
