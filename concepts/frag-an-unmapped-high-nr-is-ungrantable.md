---
type: belief
id: frag-an-unmapped-high-nr-is-ungrantable
provenance: koru-os native session — py-cpython-child rung, 2026-11
ts: 2026-11-10
tags: [native, capability, canonNr, interpreter, syscall]
---

**A bag bit only exists for classes below 64 — every nr ≥64 that a
real libc/runtime speaks must fold onto a named class or it is
ungrantable by construction.** The CPython probe made this concrete:
`getdents64`(217), `getcwd`(79), `uname`(63) arrived as
`SEAM REFUSE not in child bag` even with a fat bag — the refusal was
the *absence of a fold*, not a missing grant.

- **`canonNr` IS the capability story for high nrs.** Each fold is a
  claim: waitid→61 (wait family), clone3→57 (create family),
  cwd/path verbs→2 (fs-object class), futex/pselect6→22 (channel-wait
  class), id/time/rlimit queries→62 (proc-self metadata). Write the
  fold with the arm in mind — mapping onto a class grants nothing the
  arm doesn't implement; ENOSYS stays a separate, louder axis.
- **The probe methodology that found this:** grant a named-class bag,
  run the real binary, let `SEAM REFUSE`/`SEAM ENOSYS` lines enumerate
  the gaps. Refusal output was the spec for the next fold — no
  guessing which syscalls an interpreter needs.
- **Corollary measured bound:** the fixed user stack window is a
  budget, not a limit — CPython 3.12 init faulted one page below a
  64KiB window (va 0x7fdefcc8). With no demand-grow, window size must
  cover the workload up front (now 1MiB/child).
