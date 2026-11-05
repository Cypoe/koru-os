---
name: usb-storage
iface: koruos/blk.usb
arms: [koru-native]
lane: native-zig
needs: [usb-xhci]
accept: read sector 0 + a file off the FAT32 ESP through BOT bulk pipes
tier: qemu
status: open
evidence: —
peer: koru-desktop/providers/usb-storage
provenance: —
---

# usb-storage

BOT mass-storage: bulk in/out pipes, CBW/CSW framing, READ(10)/WRITE(10)
SCSI subset. Turns the boot stick into *runtime* storage — persistence
on real hardware without NVMe.

## Acceptance

Boot the usb-esp image, then read it back through our own driver:
sector 0 GPT header + a file's bytes off the FAT32 ESP, verified
against known content. The stick we booted from becomes a block device.

## Notes

- Falsifiable cleanly: same image two roles — firmware reads it at
  boot, our driver reads it at runtime.
- WRITE support is a separate assertion (persistence milestone).
