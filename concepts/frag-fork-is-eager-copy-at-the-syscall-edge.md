---
type: belief
id: frag-fork-is-eager-copy-at-the-syscall-edge
provenance: koru-os native session — fork/aspace rung, 2026-10
ts: 2026-10-25
tags: [native, fork, clone, aspace, syscall-abi, musl, page-tables, contract]
---

**fork is an eager address-space copy realized at the syscall edge — not a
grantable tor, and not CoW yet.** The three rulings that hold:

**The nr space is Linux's, not ours — the probe, not the guess.**
Disassembling the vendored musl `_Fork` shows it sends **nr57 with zero
args** — our spawn/fork ABI had squatted 57/58. The ruling: numbers <512
are the Linux table verbatim (a real binary's nr57 IS fork), koru's own
verbs moved to nr512/513, and `canonNr` folds 512→57, 513→58 so existing
bags keep working. `clone(56)` folds onto cap 57 too — clone and fork are
ONE "create a child" capability; the flag *shape* refusal lives inside the
arm (`flags != SIGCHLD` → "not the fork shape", ENOSYS), not in the bag.

**Eager copy, decided not defaulted.** The clone walks the parent's
user-half page tables (PD → PT → page), PMM-allocates a fresh page per
mapped leaf, and memcpys — permissions and NX preserved verbatim. CoW was
weighed and deferred *on the record*: the roster is 4 children, CoW's win
is deferred copies, and its price is a write-protect + page-refcount +
fault-time unshare path that does not exist. When fork-exec churn or
memory pressure measures it, CoW is the evolution — the frag is dated so
the choice reads as a decision, not an accident.

**The child frame is synthesized, not trap-captured.** A fork child never
took a trap — its UserFrame is built as "just returned from the syscall
gate": rip = the saved post-syscall rcx, rflags = saved r11, rsp = the
caller's recorded user rsp, rax = 0. The syscall-gate path and the int80
path carry user state in different places; the child records which gate
it entered through. Parent gets pid = roster-slot+1 — the SAME domain
wait() uses, so `waitpid(p)` resolves.

**F2 stands.** `spawn/index.kz`'s refusal — ambient address-space copy is
not a grantable capability — is untouched: no tor grants it. The ring-3
edge gets fork through the bag's cap-57 bit, which is syscall filtering,
not an aspace grant. The tor layer keeps refusing until nid-scoped grant
objects design the honest shape.

Measured: `forktest.elf` under the real musl `_Fork` — child read through
the dup'd fd returned `-from` (the SHARED OpenFile offset advanced by the
parent's own 5-byte read), private `x=42` vs parent's `x=1`, child
getpid()=3 = parent's fork return; `waitpid` reaped WEXITSTATUS=33;
`clone(CLONE_VM|...)` refused errno=38 with `SEAM REFUSE clone flags=...
(not the fork shape)` on serial; `exit=7` rode home. `forks=1 fpages=79`
in the sched line. Boot gate 32/32.
