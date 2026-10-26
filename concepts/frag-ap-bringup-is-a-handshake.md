---
type: belief
id: frag-ap-bringup-is-a-handshake
provenance: koru-os native session — INIT-SIPI-SIPI rung, 2026-10
ts: 2026-10-30
tags: [native, smp, acpi, contract, substrate]
---

A CPU's startup is a **handshake with a deadline**, never
fire-and-forget. The BSP writes a params block into the trampoline
page — CR3, stack top, entry point, the AP's own id — pulses INIT +
two SIPIs through the ICR (high dword first; the low write triggers
the send), then spins on the AP's ack with a tick-bounded bound. A
silent AP is `REFUSED` by name with its id, not an assumed success:
"the AP came up" is a claim the AP itself must make, because every
other evidence shape (IPI delivered, no fault logged) is satisfiable
by a CPU that never ran.

The SIPI landing zone is the only legal one — a page below 1 MiB —
and e820 marks it *usable*. That makes it pmm's to hand out: the
trampoline page must be `reserve()`d before it is written, or a
wrapped alloc pass can give a program the code a live AP executes.
`pin` is the wrong tool — it only takes a frame that is already held;
`reserve` saturates the refcount permanently, which is what a code
page with no owner is.

The bringup reuses what the BSP already proved rather than minting
per-CPU copies: the AP climbs the same PAE+long-mode ladder `_start`
did against the **BSP's** `pml4` and `gdt64` — absolute addresses,
legal because the image is position-fixed and identity-mapped. One
page of real-mode code is all that is per-boot; everything else is
the shared kernel.

The rung's other ruling is about module state: **path imports
instantiate per-importer**. `@import("acpi.zig")` from both `boot`
and `smp` compiles two copies of the parsed-table state — smp would
see a second, empty MADT. Shared substrate state lives in `-M`
modules wired with `--dep`; a `.zig` path import is only safe for
pure code or a single consumer. This is why `acpi` graduated from a
path import to a real module when the second consumer appeared.

Bounded on both ends: `cpus=1` prints `smp: uniprocessor` rather than
skipping silently; `apicIds` caps at 64 with the count still honest
past it.

Measured: `-smp 4` → `madt: cpus=4(4en)`, `bsp id=0`,
`ap id=1..3 online`, `3/3 ap(s) online` — each ack observed inside
the deadline. Gates: boot 56/56.
