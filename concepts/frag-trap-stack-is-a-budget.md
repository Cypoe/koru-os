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
arm that invokes fs/exec/provider chains either fits its stack or the
design moves. Nothing may silently widen the seam's depth and call it
"the allocator is broken."

Resolution (landed this rung): **every live child owns a bounded trap
context** — `kstacks[MAXCHILDREN][32KiB]`, and `resumeChild` repoints
both ring-0 entry stacks (`rsp0_val` for `syscall`, TSS.rsp0 for
CPL3 interrupts) at the resumed child's own top. An overflow now burns
only the offending child's slot, never a bystander's. Per-slot statics
match the fixed roster; a dynamic roster moves them to pmm frames with
it. What remains open is kernel-as-context proper: a parked frame is
still *evacuated* into `wait_frame`, not schedulable mid-call — the
kstack is dead scratch between user epochs, so a trap that must block
halfway through provider depth still cannot park without unwinding.

Corollary from the same rung: an allocator hint is a heuristic, not a
boundary — `pmm.alloc` scanning `hint..managed` without wraparound made
every freed frame below the hint unreachable, leaking on each alloc/free
cycle. The false ENOMEM that exposed the overflow would have become a
real one soon after.
