---
type: frag
id: frag-a-process-is-a-set-not-a-slot
provenance: clone-threads — the musl pthread flag set demanded the split
ts: 2026-11-16
---

# a process is a set, not a slot

`Child` was the process. Threads broke that: `clone(0x7d0f00)` needs
N schedulable members over ONE process — one address space, one fd
table, one disposition set, one session — so the shared facts moved
to `ProcShared` and `Child` kept only what a thread owns (frame,
kctx/kstack, `fsbase`, wait records, pending facts). `refs` counts
the members; `tgid` names the leader's slot.

The ruling that follows: **the slot is the member, the record is the
process.** Everything keyed to "the process" resolves through `sh`;
everything keyed to "the runner" stays on the child.

- `getpid` answers `sh.tgid`; `gettid` answers `slot+1`; `kill(pid)`
  matches on `tgid` — a member's slot+1 is not a pid.
- `exit(60)` dies the member — slot frees, `clear_tid` zeroes and
  wakes the join futex; `exit_group(231)` dies the tgid — members
  drop in place, the caller exits last.
- The leader's slot is the reap target FOR THE GROUP: a leader out
  early goes `.gdead` — held, neither reapable nor reusable — and
  the last member out runs the reporting once: one SIGCHLD, one
  zombie, one status. `.dead` reissues freely; `.gdead` is the held
  slot that prevents a fresh spawn aliasing the group's reap target.
- `exec` on a member kills the rest of the group first (de_thread's
  own shape) — the shared table survives, the upd unmaps only after
  the refs drop makes it private.
- Signals are group facts: a fatal signal to any member is a group
  death (`tgkill` still names the member slot — delivery, not
  scope). Fork is NOT a member: it allocs a fresh record, copies the
  shared fields, gets its own `tgid`.
- The slot-count discipline: threads and processes draw the same
  roster — a tgid is a set OF slots, so `MAXCHILDREN` sizes the
  whole runnable population, not a process count.

The same rule scales further than pthreads: `CLONE_FILES` without
`CLONE_VM` (a container primitive), `CLONE_PARENT`, and namespaces
all decompose into "which ProcShared fields does this member bind
or unshare?" — the flag matrix stops being monolithic the moment
process facts stop living on the runner.
