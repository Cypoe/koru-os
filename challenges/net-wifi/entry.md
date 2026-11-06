---
name: net-wifi
iface: koruos/net.wifi
arms: [koru-native]
lane: native-zig
needs: [net-virtio]
accept: an Intel/Atheros-class wifi driver associates on real hardware — far-future, file for the ledger
tier: hw
status: open
evidence: —
peer: koru-desktop lists wifi in its provider catalog
provenance: —
---

# net-wifi

Real wireless: mac80211-class is the largest driver surface a
desktop can ask for — firmware load, scan, associate, WPA. Filed so
the ledger names the gap honestly; nothing here is near-term.

## Acceptance

On the hw tier: a real NIC associates to a test AP and ICMP
completes. Until then this slot is a name and a boundary.

## Notes

- Sits far behind net-virtio (the lwip/virtio path first) and the
  PCI/firmware-loading rungs. The honest first mile is `iw`-class
  firmware upload through the blob loader, not the protocol stack.
