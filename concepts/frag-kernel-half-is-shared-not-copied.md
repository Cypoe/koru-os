---
type: belief
id: frag-kernel-half-is-shared-not-copied
provenance: koru-os native session — IOAPIC routing rung, 2026-10
ts: 2026-10-26
tags: [native, aspace, mmu, interrupts, lapic, oracle-lesson]
---

A child's CR3 carries the kernel half **by reference, never by
snapshot**. The child's pdpt copies the kernel's pdpt entries — every
slot points at the kernel's own pd — so any mapping the kernel makes
(boot-time mmio windows, later devices in an existing slot) exists on
the child's tables by construction. Only the user window (pdpt[1])
is per-child. A snapshot of the kernel's tables is wrong by
definition: it records what was mapped *at spawn*, and every window
minted after that copy is a hole the child will fall through the
first time an interrupt fires on its CR3.

The failure mode this prevents is silent for exactly as long as
nobody needs it: PIC EOI is **port** I/O (`outb 0x20`) — the 8259
door never touches memory, so child-CR3 interrupt handling worked
for months with the LAPIC/IOAPIC/BAR windows (all >1 GiB, living in
hi-window pds no child had) simply absent. LAPIC EOI at 0xFEE000B0
was the *first* write any interrupt path ever made on a child CR3
— and every disk/timer IRQ landing mid-child raised #PF at
`va=fee000b0` the moment IOAPIC routing went live. Port I/O hides
address-space holes; MMIO finds them on the first delivery.

Adjacent oracle lesson, worth its own sentence: `0xFEE00000` reads
as "high MMIO" but sits at GB3 of the pdpt — the bug report read as
"the child lacks a kernel mapping" while the actual statement was
"the child lacks *every* mapping above 1 GiB." Name the slot, not
the address.

The refusal rule stands with it: a kernel window already occupying
pdpt[1] is an unresolvable overlap with the user window — refused
by name at table-build, never silently shadowed.

Measured: `#PF va=fee000b0` killed every child-context IRQ row
(fs-child/dynamic/ext2 cluster, one crash poisoned boot_real.serial
for 11 rows); after sharing, boot 58/58 with every IRQ — PIT via
GSI2, kbd/mouse, virtio INTx — LAPIC-delivered on child CR3s.
