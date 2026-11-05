---
name: smp-multirunner
iface: koruos/sched.smp
arms: [koru-native]
lane: native-zig
needs: []
accept: -smp 4 with 2+ children claimed on different CPUs, parallel ticks
tier: qemu
status: open
evidence: —
peer: —
provenance: —
---

# smp-multirunner

APs claim and run children today — single-runner. The real rung:
concurrent user execution on >1 CPU — per-CPU TSS/syscall stacks
exist, the claim is exclusive, so what's missing is parallel claims +
per-CPU IOREDTBL destinations + whatever sharing the fd tables and
channel rings actually tolerate.

## Acceptance

-smp 4 fixture: two children running simultaneously on different CPUs
(evidence: distinct APIC ids in serial across one wall-clock window),
each taking ticks, exiting cleanly.

## Notes

- Shared-kernel-structure audit is the real work — pipes/socks/pty
  rings, fd tables, pmm free list are all single-runner today.
- Owner-id BKL already exists as the honest fallback shape.
