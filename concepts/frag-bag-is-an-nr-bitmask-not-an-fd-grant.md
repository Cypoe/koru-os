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

Named caveat that follows: a real cap-mode child must be static — dynamic
rtld opens libs by path → ECAPMODE. Extern-ELF ambitions (fish/foot/
Quickshell) run fine on the linux arm; under Capsicum they want static
builds or a casper-style loader.
