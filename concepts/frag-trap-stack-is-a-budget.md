---
type: belief
id: frag-trap-stack-is-a-budget
provenance: koru-os native session — shell-REPL rung, 2026-10
ts: 2026-10-25
tags: [native, kernel-stack, syscall, corruption, contract]
---

Every syscall's execution **budget includes the trap stack**. The seam
runs each trap on one shared rsp0 — a syscall that calls provider depth
(path walk → ext2 → virtio → streamed ELF load, one 4KiB header buffer
on the frame alone) must be paid for in stack, or the overflow lands in
adjacent `.bss` and speaks in a foreign voice: `pmm.alloc` refusing with
thousands of frames free, `free` reporting "unowned" frames that were
never allocated, a #GP on an instruction that cannot fault. The symptom
names the victim, never the cause — which makes this corruption class
expensive to find and cheap to prevent.

The ruling: **deepening the seam is a stack-budget decision.** A syscall
arm that invokes fs/exec/provider chains either fits the declared rsp0 or
the design moves — per-task kernel stacks are the honest end-state (the
shared 64KiB bump is a stopgap that works because the trap frame is
*abandoned*, not stacked, on a parked child). Nothing may silently widen
the seam's depth and call it "the allocator is broken."

Corollary from the same rung: an allocator hint is a heuristic, not a
boundary — `pmm.alloc` scanning `hint..managed` without wraparound made
every freed frame below the hint unreachable, leaking on each alloc/free
cycle. The false ENOMEM that exposed the overflow would have become a
real one soon after.
