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
then *parks the spawner itself* on `wait_pid` — the identical
TrapFrame→UserFrame rebuild `coninRead` uses. The child's exit arm is the
wake: it writes its status into the parked parent's `gp[0]` and flips it
runnable. The spawn syscall's return value IS the child's exit status;
there is no separate waitpid syscall to design first.

Two wait keys now exist and the roster treats them uniformly — a
`.blocked` child names what it waits on (`wait_buf`/`wait_cap` for a
conin byte, `wait_pid` for a descendant) and the epoch holds open while
any `.runnable` OR `.blocked` remains. Generalizing to a wait-key table
is mechanical from here, not architectural.

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
