---
type: belief
id: frag-spawn-parks-on-exit
provenance: koru-os native session — shell-REPL rung, 2026-10
ts: 2026-10-25
tags: [native, spawn, sched, wait-keys, syscall, contract]
---

Wait-on-exit is the **same machine** as wait-on-input, not a second
primitive. `ring3_trap` nr 57 (`childSpawn`) names a path through the
caller's own scoped fs view, builds the child (fresh tables, streamed
`loadElfViaFs`, PT_INTERP through the same view), primes its UserFrame,
then *parks the spawner itself* — `while (child alive) kblock(.exit)`.
The child's exit arm writes the status into the waiter's `spawn_ret`
(living in the waiter, so dead-slot reuse can't clobber it) and marks it
runnable; the resumed spawn call returns the status as rax itself.

Mechanism evolved (2026-10): the park is now a suspended kernel
continuation on the parent's own kstack — see
`frag-block-is-a-kernel-continuation`. The semantic above is unchanged:
spawn's return value IS the child's exit status; no waitpid primitive.
`.blk` joined `.conin` and `.exit` as a third wait kind — virtio DMA
waits mid-call now schedule the roster instead of halting (`yields=` in
the blk stats is the measured evidence).

Rights on the seam: the spawned bag is `requested ∩ parent's bag` —
a child can shed capabilities, never grow them. A `fork()` from musl
lands on nr 57 with a non-path rdi and gets EFAULT loudly; claiming a
Linux syscall number means claiming its honest failure too.

Arguments ride the same seam as a **NUL-separated blob**, not an execve-
style pointer array (2026-10): `spawn(path, rights, blob, blob_len)` —
one bounded copy out of the caller's space, no two-level chase through
user pointers, and the malformed cases are loud: oversized block
-EINVAL, unmapped -EFAULT, past `MAXARGS` -E2BIG. Absent blob keeps the
old contract: `argv[0]` is the path the caller named. The shell
tokenizes its line; argv[0] stays the name *as invoked* while path
resolution (`bin/` prefix) is a lookup detail, not an argument.
Oracle lesson: an unterminated blob tail is a legal last arg, but the
on-stack copy must still terminate — a `%s` scan past `USER_STACK_TOP`
faults exactly at the window's edge, and it looks like a stack-layout
bug for hours before the missing byte is seen.

Evidence: `sh.elf` (musl REPL) prompts `koru> `, parks, takes
`pie.elf\n` via monitor sendkey, spawns it — serial shows
`real pie child says hi`, `pmm: reap freed=18`, then `exit=42` printed
BY THE SHELL from the syscall's rax — `q\n` exits 47. The gate row
(`shell-repl`) refuses a pass unless the prompt was observed before any
sendkey.
