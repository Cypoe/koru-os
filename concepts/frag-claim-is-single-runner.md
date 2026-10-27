---
type: belief
id: frag-claim-is-single-runner
provenance: koru-os native session — claim-and-run SMP rung, 2026-11
ts: 2026-11-05
tags: [native, smp, sched, locking, irq, contract]
---

The roster's honest contract is **one child in user mode at a time**,
claimed by whichever cpu the rotation names — not "each cpu its own
child". `exec_cpu` is the single license (the seam's ring-transition
globals name THE running child); a child migrates only across
block/exit/tick boundaries, and `exec_hint` + the resched IPI are the
designated-next mechanism, not a race. Dissolving the singleton needs
per-CPU user state (swapgs) — a later cell, not this one.

The disciplines that make the claim correct are all about WHERE a cpu
may stand when another cpu can touch the stack:

- **The BKL names its owner.** A boolean lock can't distinguish "I hold
  it" from "a peer holds it" — an IRQ landing on the holder must know
  which it is. `bkl` stores `cpu+1`; acquisition is CAS-expecting-0 (a
  spinning xchg would clobber the owner id and make the holder's own
  nested IRQ fail the owner check — a self-deadlock).
- **Device waits under the lock still need a real exit.** An IF=0
  pure-memory poll inside a BKL-held device wait starves QEMU's async
  completion path — TCG services the virtqueue's used-ring update on
  vCPU exits, and a poll yields none (the request retires *seconds*
  late; `-accel tcg,thread=single` makes it deterministic). The legal
  wait is `sti;hlt` *while holding the lock*: interrupt gates clear IF
  on entry, so the IRQ runs nested on the holder's stack — bounded
  ack/mark/EOI work — never re-locking, never unlocking.
- **An IRQ on one cpu must wake a waiter on another.** Under SMP the
  INTx lands on the routing target while the BKL-holder hlt's on a
  different cpu; only its own tick would wake it (measured: tens of
  seconds of tick-paced waits). `kickHolder` sends the resched IPI to
  the bkl owner from any device arm — a pure wake that exits its hlt.
- **The scheduler never parks on a resumable stack.** schedLoop reaches
  its `hlt` standing on whatever stack brought it there — a child's
  kstack via `ksched`, a ticked child's via the IRQ, a dead child's via
  exit. The roster may hand that same child to ANOTHER cpu while the
  first is still parked below its saved block; the resumed continuation
  then writes over the parked cpu's live frames (observed: a `ret` into
  stack bytes → #UD at a stack address). Every scheduler entry hops to
  a per-CPU sched stack first (`schedEnter`), and `releaseExec`'s kick
  runs only after the hop — kicking the designee while still standing
  on the resumable stack is the same race at a narrower window.
- **Per-CPU state is TSS slots + MSRs, not per-CPU globals.** Each cpu
  arms its own TSS descriptor in the shared GDT (rsp0 per cpu), its own
  syscall MSRs, the shared IDT, its own LAPIC LVT. `rsp0_val` stays a
  singleton because the claim is a singleton — consistent granularity.
- **ABI parity survives the hop.** A `jmp`-entered noreturn body still
  expects `rsp ≡ 8 (mod 16)` — the top slot of the fresh sched stack is
  the fake return address; enter aligned and `movaps` spills #GP.

Measured: `boot_smp` row — 3 APs tick on their own LVTs, roster mask=f,
and `sched: slot<N> claimed by cpu1/2/3` each running a child
end-to-end (designated rotation, not a race). `boot_real` + the three
dynamic rows pass under the claim — dynamic ELF exec (PT_INTERP →
ld-musl/libc streaming) was the workload that found every one of these
invariants. Gates: boot 59/59, realize 13/13.
