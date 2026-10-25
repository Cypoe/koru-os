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

Evidence: `sh.elf` (musl REPL) prompts `koru> `, parks, takes
`pie.elf\n` via monitor sendkey, spawns it — serial shows
`real pie child says hi`, `pmm: reap freed=18`, then `exit=42` printed
BY THE SHELL from the syscall's rax — `q\n` exits 47. The gate row
(`shell-repl`) refuses a pass unless the prompt was observed before any
sendkey.
