---
type: belief
id: frag-a-pgrp-is-an-identity-not-a-number
provenance: koru-os native session — sessions-jobctl rung, 2026-11
ts: 2026-11-10
tags: [native, pgrp, sessions, lifetime, aliasing, correctness]
---

**A process group is an identity; the number is only its name
while it lives.** The pty's `fg_pgrp` is stored as a pgid *value*,
and slot reuse nearly shipped a real security bug through it:

1. Job 2 (slot 2, pid 3) takes the foreground via `TIOCSPGRP`, then
   dies — `fg_pgrp` keeps pointing at `3`.
2. Job 3 reaps into the **same slot** → pid 3 again →
   `setpgid(0,0)` makes pgid 3.
3. `ptySlaveRead`'s TTIN check compares `effPgid(child) ==
   t.fg_pgrp` → `3 == 3` → the new, never-foregrounded job reads
   the tty unchallenged and parks forever. The test *hung* instead
   of failing — the alias made a background reader look
   foreground.

Linux doesn't alias because `tty->pgrp` is a `struct pid*`
backref cleared when the pid dies — the pointer dies with the
identity it names. Our numeric equivalent is `fgSweep`: on every
reap path (`childDie`, `childReap`, and `wait`'s zombie→dead
transition — a zombie still holds its pgrp like linux's un-reaped
task) scan the ptys and clear an `fg_pgrp` with no live members.

The rule generalizes beyond ptys: **any reference stored as a
numeric id must be swept wherever that id's referent dies** —
`spawned_by`, `wait_pid`, `ctty`, `owner` are the same shape.
Ids that outlive their referent are not handles; they are
reservations for the next tenant.
