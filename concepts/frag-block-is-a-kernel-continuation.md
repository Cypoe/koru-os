---
type: belief
id: frag-block-is-a-kernel-continuation
provenance: koru-os native session — kernel-as-context rung, 2026-10
ts: 2026-10-25
tags: [native, sched, blocking, syscall, wait-keys, contract]
supersedes: frag-wake-completes-the-parked-syscall
---

A block is a **suspended kernel continuation**, not a rebuilt user frame.
Per-child kstacks made it possible; `kblock` is the whole mechanism: push
callee-saved on the running child's own kstack, store rsp in `c.kctx`,
mark `.blocked` + `wait_kind`, schedule. The waker is a mark-only write —
`.runnable` — and `switchInto` restores CR3 + pops the block + `ret`s;
the call resumes mid-provider-depth and the syscall completes itself
through the entry path it arrived on. `wait_frame`, entry-faithful tail
rebuild, `from80`, and every wake-side user-buffer write are gone: three
wait kinds (conin byte, blk request, child exit) share one primitive.

The discipline that makes it correct:

- **Check-under-mask, always.** The wait condition is re-tested under
  `cli` immediately before marking `.blocked` — a byte/request landing
  between the empty check and the mark is a lost wake and a permanent
  stall. `kblock` is callable only with IF=0; `schedLoop` `sti`s after
  `kctx` is stored, publishing the mark atomically wrt IRQs.
- **Wake is a mark, resume is a re-decision.** `wakeKind` never completes
  work — the resumed continuation re-drains/re-checks and re-blocks if
  the wake was spurious. That tolerates broadcast wakes (one virtio IRQ
  wakes every `.blk` waiter; each re-decides).
- **Per-syscall globals die under suspension.** `child_ursp` is written
  at every syscall entry — a blocked trap outlives it (the grandchild's
  syscalls overwrote it; the parent's `sysretq` epilogue then loaded a
  dead child's rsp). The trap snapshots it into `c.ursp` at entry and a
  `defer` publishes it back before any return reaches the epilogue.
- **Kernel-context resume restores CR3 too.** The kctx path must reload
  the child's `pml4` — a wake can land on a bystander's address space
  (the exit arm ran on the *dying* child's CR3; resuming the parent
  without restoring it fetched user code through reaped tables → #PF).
- **A returned value may not ride in the dead child's slot.** A slot is
  reusable the moment it's `.dead`; the exit arm writes the status into
  the *waiter's* `spawn_ret` before marking it runnable, so slot reuse
  can never clobber the payload.

What remains distinct: tick preemption stays frame-based (a CPL3
`ExcFrame` copied into `c.frame`), and preempt *skips* runnable children
with live `kctx` — they resume at the next schedLoop/exit boundary, a
known latency bound, not a deadlock. Tick-driven kernel preemption is
the open piece of kernel-as-context.
