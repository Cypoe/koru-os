---
name: proc-roster-view
iface: koruos/proc.view
arms: [koru-native]
lane: native-zig
needs: []
accept: a child reads a read-only roster view — every child's pid/pgrp/state/bag as data, no /proc lie
tier: qemu
status: landed
evidence: V
peer: —
provenance: —
---

# proc-roster-view

CC's `top`-as-bridge-scanner, our shape: the kernel already knows
every child's pid, pgrp/sid, state, spawned_by, rights bag, and fd
kinds — a read-only view over the roster is data, not a filesystem
fiction. `nr522 procview()` mints an fd holding a generated snapshot:
one `pid=N ppid=N pgid=N sid=N st=X stop=N bag=0x.. ctty=N nfd=N`
line per live slot. Snapshot-at-open is the honest "what was true
when you asked" — dup shares the cursor (one open file description).

## Acceptance — MET (QEMU serial)

`boot_roster` → cpio `/bin/roster` under a tight bag (proc class only —
nr522 folds to cap 62, /proc's world-readable contract). 21 checks,
`RV COMPLETE fails=0`, status=0: self mid-read st=R, peer parked 'S'
in pause(), zombie 'Z', SIGTSTP→'T'+stop=20, SIGCONT resume, reaped
child gone, ppid/pgid/sid fields, bag/nfd, shared-cursor dup, EOF,
write-refusal. The suite synchronizes THROUGH the view — `wait_st`
polls states instead of sleeping; no pipes, no sleeps needed.

## Notes

- Landed the `pause` arm (nr34) with it — the suite measured the gap:
  park on `.pause`, a deliverable (unmasked, unignored) signal fact
  wakes it, returns EINTR. jobctl never probed it (its jobs parked on
  pipe reads).
- Corrected `pgrpOrphaned`: `sid==0` is the bootstrap session, a real
  session-shaped set — the old `sid != 0` guard suppressed every
  job-control stop until someone called setsid.
- This is the observation surface a navigator (Kopium) needs later —
  "what is open, by whom, with which rights" is a first-class
  question on this kernel, not a /proc scrape.
