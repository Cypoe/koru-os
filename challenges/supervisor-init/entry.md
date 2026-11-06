---
name: supervisor-init
iface: koruos/proc.supervise
arms: [koru-native]
lane: native-zig
needs: [sessions-jobctl]
accept: the boot program respawns a killed child per policy — let-it-crash as the init shape
tier: qemu
status: open
evidence: —
peer: std/supervisor (upstream/koru-libs) — the erlang-shaped while-loop
provenance: —
---

# supervisor-init

Init as a supervisor, not a process list: the boot program declares
children + restart policy (`one_for_one`, intensity caps), a killed
child respawns with a fresh bag, and a child past its intensity
budget is abandoned — the failure accounting is the policy's, not
the kernel's. std/supervisor's shape applied where it belongs.

## Acceptance

Boot fixture spawns a child that exits(7) once then runs clean; the
supervisor respawns it exactly once (serial shows the respawn + the
second child's own line), and a crash-looping child is abandoned
after its intensity budget — both measured on serial. status=0.

## Notes

- The pieces exist: spawn respawn is a loop over nr512/513 +
  wait(61) statuses — the policy is a .k-level structure, no kernel
  change needed. This slot measures whether that's TRUE.
- CC's `std/supervisor` (the erlang/polly while-loop) is the
  vocabulary — the boot program becomes its first real consumer.
- Connects to proc-roster-view: the supervisor's accounting is what
  a bridge scanner should see.
