---
type: belief
id: frag-tick-is-local-hardware
provenance: koru-os native session — AP roster-substrate rung, 2026-10
ts: 2026-10-26
tags: [native, smp, lapic, scheduler, contract]
---

There is **no shared tick**. The PIT's IRQ0 is one wire to one
destination; a second CPU that wants a heartbeat programs its own
LVT timer — local timers are per-CPU hardware living at the same
MMIO address on every core. The roster consequence: *a schedulable
CPU is one that takes kernel interrupts on its own armed tables* —
IDT loaded, LAPIC enabled, LVT ticking. Everything else about
roster membership (claim a child, run it, preempt it) is software
built on top of that one hardware fact.

Calibration has exactly one honest source this early: the PIT.
Program the LVT one-shot at full count, wait two IRQ0 ticks
(~110 ms), read back the elapsed count, halve it — the quotient is
the period for a ~18 Hz per-CPU tick, no bus-frequency table to
trust or fake. QEMU i440fx measures ~3.4M counts per tick; the
number is firmware's to give, never ours to assume.

Symmetry is deliberately deferred: the BSP keeps the PIT tick it
always had (IRQ0 is already destined to it through the IOAPIC);
APs take LVT ticks. Both doors deliver "the local timer" — the
dispatch treats the LVT vector like the message-signaled arm
(LAPIC EOI), because that is what it is.

Measured: `-smp 4` → `ap id=1 ticks=25`, `id=2 ticks=23`,
`id=3 ticks=21` inside ~1.1 s of wall — three CPUs each running
kernel interrupt context on the shared IDT; `roster mask=f`.
