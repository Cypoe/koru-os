---
name: proc-roster-view
iface: koruos/proc.view
arms: [koru-native]
lane: native-zig
needs: []
accept: a child reads a read-only roster view — every child's pid/pgrp/state/bag as data, no /proc lie
tier: qemu
status: open
evidence: —
peer: —
provenance: —
---

# proc-roster-view

CC's `top`-as-bridge-scanner, our shape: the kernel already knows
every child's pid, pgrp/sid, state, spawned_by, rights bag, and fd
kinds — a read-only view over the roster is data, not a filesystem
fiction. A `top`-like child reads it through a channel door or a
mounted fs view and prints the live table.

## Acceptance

A musl child opens the roster view and prints one line per live
child (pid, pgid, state, bag bits) — including ITSELF, mid-read.
Three children live simultaneously; all three appear. status=0.

## Notes

- This is the observation surface a navigator (Kopium) needs later —
  "what is open, by whom, with which rights" is a first-class
  question on this kernel, not a /proc scrape.
- Not a procfs clone: the view is read-only, real-time, and carries
  OUR fields (bags, grants, pgid, ctty) — no fake Linux field
  soup unless a compat shim asks for it.
