---
type: belief
id: frag-bag-is-an-nr-bitmask-not-an-fd-grant
provenance: koru-os hosted session — FreeBSD/Capsicum arm, 2026-10
ts: 2026-10-24
tags: [spawn, rights, capsicum]
---

The spawn rights bag is a **syscall-number bitmask**: "which *calls* may you
make". Capsicum's `cap_rights_t` is **per-descriptor**: "which *objects*,
and how". These are different axes, and pretending otherwise is the lie the
hosted freebsd arm exists to catch — the shim reports unmapped NR bits
rather than silently granting.

Held consequence: bag v2 is the nid-scoped grant-object design — grants name
*objects* (the axis Capsicum proved real), not calls. That is the standing
`nr-bitmask → lift grant objects` item, and the reason it is standing, not
optional: the NR axis cannot express "this fd, read-only" — the object axis
cannot be approximated by syscall filtering without false precision.

**Evolved (real-ELF rung):** the bits are now formally *capability
indices*, not raw NRs — real binaries need the Linux NR table, and NRs
≥64 (arch_prctl 158, set_tid_address 218, set_robust_list 273,
prlimit64 302, getrandom 318, exit_group 231) have no bit. `canonNr`
folds them onto reserved caps — 62 "proc-self metadata", 61 "entropy",
231→60 (exit_group IS exit for single-threaded children). The fold
table is interim plumbing that proves the bitmask's days are numbered:
the cap groupings it invents are exactly what grant objects replace.
Also corrected on contact: getpid is NR 39, not our invented NR 2 —
a real binary's `open(2)` must never resolve to a getpid answer.

**Evolved (fork rung):** the low numbers are Linux's table VERBATIM —
musl `_Fork` sends nr57 with zero args, so our spawn/fork verbs moved
to nr512/513 (folded back onto caps 57/58 so bags keep working).
`clone(56)` folds onto cap 57: clone and fork are one "create a child"
capability; the flag-shape refusal lives in the arm, not the bit.
`rt_sigprocmask(14)` folds to cap 62 (proc-self). Every fold is one
more hand-named cap grouping — the bitmask keeps enumerating the
objects the grant-bag design must name.

Named caveat that follows: a real cap-mode child must be static — dynamic
rtld opens libs by path → ECAPMODE. Extern-ELF ambitions (fish/foot/
Quickshell) run fine on the linux arm; under Capsicum they want static
builds or a casper-style loader.
