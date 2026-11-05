---
name: acpi-s3
iface: koruos/power.s3
arms: [koru-native]
lane: native-zig
needs: []
accept: S3 sleep + wake resume in QEMU (fw_cfg or RTC wake)
tier: qemu
status: open
evidence: —
peer: koru-desktop/providers/acpi-s3
provenance: —
---

# acpi-s3

Suspend/resume: S5 powerctl and 8042 reboot exist; S3 means saving
device state, writing _S3 to pm1a, and coming back through the wakeup
vector — a real resume path, not a cold reboot.

## Acceptance

QEMU fixture: enter S3, wake (RTC alarm or fw_cfg), and the kernel
resumes with children intact — serial shows suspend+resume markers
and the same child continues.

## Notes

- Resume means the trampoline path runs twice — second entry must
  re-init LAPIC/IOAPIC/IDT state that firmware reset.
- QEMU's S3 support is partial; honest tier-hw notes may force the
  qemu row to a reduced assertion (state-save + simulated wake).
