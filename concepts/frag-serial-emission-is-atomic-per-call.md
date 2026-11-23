---
type: belief
id: frag-serial-emission-is-atomic-per-call
provenance: koru-os native session — comp-scene serial splice postmortem, 2026-11
ts: 2026-11-22
tags: [native, serial, console, irq, evidence, contract]
---

**A serial line is only as atomic as its weakest emit call: compose
the message, then emit it once.** `comp: attach irq: timer delivered`
wasn't a lost write — the full `320x200 at 40,40 z=0` tail survived as
an orphan on the next line. A timer IRQ had landed between two of the
eight `koru_say`/`koru_putdec` calls composing the attach line, and the
kernel console faithfully wrote both byte streams in order. The splice
destroyed the *line boundary* a gate greps for, not the bytes.

The tempting wrong fix is the bkl: it already serializes every kernel
body — except the nested-IRQ arm, which runs on the lock-holder's own
CPU *without* re-locking, by design. That arm is the splicer. The only
primitive that closes it is `cli`: `pushfq; cli` … `popfq` around each
emit loop defers delivery until the message completes, and `popfq`
restores IF rather than force-enabling it, so the same path is safe
inside the IRQ handler itself (IF already clear).

Held consequence — per-call atomicity is necessary but not sufficient:
`cli` inside `fputs` protects one call, and a logical line built from
eight calls still has seven splice points. The doctrine is one logical
message = one emit call: providers format into a stack buffer
(`koru_sayf`/`std.fmt.bufPrintZ`, the idiom fb.zig already established)
and emit once. Userspace conout write/writev hold the same guard across
the full iov walk. Remaining multi-call diagnostics interleave only at
piece boundaries — whole fragments, never mid-token.
