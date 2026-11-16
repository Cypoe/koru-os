---
name: clone-threads
iface: koruos/proc.thread
arms: [koru-native]
lane: native-zig
needs: []
accept: clone(CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND|CLONE_THREAD|SETTLS|SETTID|CLEARTID|DETACHED|SYSVSEM) mints members on one ProcShared; join parks on clear_tid futex; exit_group reaps the tgid once
tier: qemu
status: landed
evidence: check-boot clone-threads row — THR COMPLETE fails=0, klanker-child KL thread 41
peer: —
provenance: —
---

# clone-threads

Real threads inside one child domain: `clone(0x7d0f00)` — the full
musl pthread flag set — mints a member sharing the caller's
`ProcShared` record (one `upd`, one fd table, one disposition set,
one session) while the per-member state stays on `Child`: frame,
kctx/kstack, `fsbase`, wait records, pending facts.

Landed pieces:

- `ProcShared` extraction — fd table, sig dispositions, brk/mmap
  cursors, session facts and the shared `upd` moved off `Child` into
  a refcounted record; fork allocs a fresh one, clone-members attach
  to the caller's. `refs` is the group's heartbeat.
- `clone` dispatch: `0x11` stays the fork arm; `0x7d0f00` is the
  thread arm (own pml4/pdpt over the shared upd — CR3 switch per
  member, one address space); anything else refuses ENOSYS by name.
- `getpid`→tgid (leader slot+1), `gettid`→member slot+1,
  `set_tid_address` stores the join word, `tgkill` targets a member
  of the caller's group.
- `futex` WAIT/WAKE on the VA (wait key domain-separated from ring
  ids by USER_VA_BASE); member death zeroes `clear_tid` and wakes
  the join futex — `pthread_join` is exactly that pair.
- `exit` (member) vs `exit_group` (tgid): a member's death frees its
  own frames and drops a ref; the leader's slot goes `.gdead` (held,
  not reapable) when it exits early; the last member out runs
  `groupReap` — one SIGCHLD, one zombie, one status per tgid.
- `exec` on a thread kills the rest of the group first (de_thread
  shape — the leader slot stays the reap target).
- `kill(pid)` resolves pid as a tgid, never a member tid; a fatal
  signal is a group death, not a lone member's.

## Evidence

- `threadtest.c` oracle: `pthread_create`+`join` (retval 7),
  member `printf` through the shared fd table, member `getpid` ==
  leader pid with distinct `gettid`, two concurrent members on a
  shared cursor, detached member run+exit — `THR COMPLETE fails=0`.
- klanker row: `KL thread 41` — a CPython `threading.Thread` member
  wrote through the shared space; was `RuntimeError can't start new
  thread` before this rung.
