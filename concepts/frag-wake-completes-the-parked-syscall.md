---
type: belief
id: frag-wake-completes-the-parked-syscall
provenance: koru-os native session — console-input wait-queue rung, 2026-10
ts: 2026-10-25
tags: [native, sched, blocking, syscall, irq, contract]
status: superseded
---

Superseded by `frag-block-is-a-kernel-continuation` (2026-10): the
kernel-context switch generalized blocking — a parked child now suspends
its own call on its own kstack and the wake is a mark, not a completion.
This frag's invariants (entry-faithful rebuild, wake writes the return)
described the evacuation mechanism, which no longer exists. The durable
pieces that still hold: a blocked child is `.blocked` not dead
(`anyLive`), and all-blocked legitimately halts the CPU.

A blocking read is a **state**, not a return code. `read(0)` on an empty
console ring does not answer 0 or EAGAIN — the child rebuilds its syscall
TrapFrame as an iret-resumable `UserFrame`, parks `.blocked`, and the
**wake side completes the syscall**: `wakeConin` writes the landed bytes
into the parked buffer (each page checked), writes the count into `gp[0]`
— the saved rax — and flips the child runnable. The resumed child lands
after the `syscall` with the return value already where the ABI wants it;
the trap path never re-runs.

Three invariants the shape taught:

- **A parked frame is entry-faithful.** `syscall` lands user rip in rcx,
  rflags in r11, rsp in `child_ursp`; `int 0x80`'s hardware frame already
  carries the iret tail at `st[15..19]` below the GP block. `from80`
  selects the tail source — park through either gate and the resume is
  complete, never synthesized wrong.
- **The epoch drains on all-dead, not all-runnable.** `nextRunnable`
  null is "nothing to run", not "done": a `.blocked` child holds the
  roster open (`anyLive`), so a sibling's exit arm halts on rsp0 instead
  of returning to the spawn caller with a parked orphan behind it. A
  shell waiting on input blocking its epoch forever is correct — that is
  what a real runqueue does.
- **All-blocked halts the CPU, and the wake ends the halt.** `sti; hlt`
  on rsp0; `schedPreempt` sees `cs&3==0` and does not rotate, so the only
  resume is IRQ1's own write. The keyboard's console ring is a *second*
  ring — ASCII from set-1 makes — disjoint from the scancode ring that
  `koruos/input` polls; one contract feeds the seam, the other feeds
  read(0).

Evidence: `getc.elf` prints `?> `, parks, and sits — QEMU stays up with a
silent serial — until a monitor `sendkey k` fires IRQ1; `GOT=k` and
`status=42` follow. The gate row gates on the prompt appearing *before*
the key, so a pre-loaded ring (the drain path, no block) cannot fake a
pass.
