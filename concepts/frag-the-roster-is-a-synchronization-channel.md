---
type: belief
id: frag-the-roster-is-a-synchronization-channel
provenance: koru-os native session — proc-roster-view rung, 2026-11
ts: 2026-11-10
tags: [native, roster, observation, synchronization, correctness]
---

**A readable roster is a synchronization channel, and a test that
polls it needs no sleeps and no handshake pipes.** The rung that
landed `nr522 procview` wrote its oracle backwards from the usual
shape: instead of sleeping and hoping a child converged, the parent
polls `st=` until the child reports `S` (parked in pause — so its
setpgid provably ran), `Z`, or `T`. The view is the barrier. Two
consequences worth keeping:

- **Observable state must be *true* state, or the channel lies.** The
  rung measured `pause()` (nr34) missing entirely — no arm, the child
  exited instead of parking — and `pgrpOrphaned` suppressing every
  job-control stop because `sid==0` was coded as "no session" rather
  than the bootstrap session it is. Both surfaced only because the
  view is honest enough to synchronize on; a faked field would have
  turned the barrier into a flake generator.
- **Snapshot-at-open is the honest liveness contract.** A roster fd
  answers "what was true when you asked", dup shares the cursor (one
  open file description), and every accessor mints fresh. Nothing in
  the view pretends to be the roster itself — that distinction is
  what a navigator (Kopium) later queries without ever touching a
  /proc-shaped lie.
