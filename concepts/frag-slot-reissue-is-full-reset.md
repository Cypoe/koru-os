---
type: belief
id: frag-slot-reissue-is-full-reset
provenance: koru-os native session — klanker-child writable-fs pass, 2026-11
ts: 2026-11-10
tags: [native, scheduler, child-slots, correctness]
---

**A reissued child slot must carry NOTHING from the previous tenant —
the reset is the contract, not an optimization.** `koru_spawn_run`
was the one slot-allocation path that re-primed a `Child` without the
`c.* = .{}` reset the nr512/nr57 paths already ran. A child killed
while blocked kept a live `kctx` naming a kernel continuation parked
on its own static kstack; `freeChild` released page tables but left
every logical field. When a later epoch reissued the slot,
`switchInto` saw the nonzero `kctx`, resumed the old continuation, and
`ret`'d through the stale chain — observed as `#UD` at `rip=3` after a
reaped-blocked python subprocess's slot recycled into the embedded
selftest epoch.

- **Kill leaves state.** `freeChild` frees frames; it is not a slot
  reset. `stopped`/`wait_kind`/`kctx`/grants/fd projections/sig state
  all outlive the tenant that made them.
- **Reset is structural, not enumerative.** `c.* = .{}` covers fields
  added tomorrow; a hand-listed reset silently goes stale. Defensive
  `freeChild` first if `upd != 0` so a never-reaped live table can't
  leak either.
- **Continuation pointers are the landmine class.** Any field whose
  value is "resume somewhere" (kctx, saved rsp/rip, pending dent
  records) must default to empty on reissue — a stale pointer is
  worse than a stale counter because it converts reuse into a wild
  jump instead of a wrong value.
