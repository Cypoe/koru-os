---
type: belief
id: frag-interrupts-have-two-doors
provenance: koru-os native session — virtio-gpu/MSI-X rung, 2026-10
ts: 2026-10-26
tags: [native, interrupts, msix, lapic, substrate, contract]
---

The IDT vector space is a **partitioned resource with two delivery
doors**, and a device picks its door by capability, not by provider
preference:

- vectors 0–31: exceptions (CPU-sourced).
- 0x20–0x2F: legacy lines — INTx and ISA IRQs. Once MADT's IOAPIC
  is live, these ride IOREDTBL entries to the LAPIC: the mask bit
  is in the redirection entry, the EOI goes to the LAPIC (it is
  also the IOAPIC's remote-IRR clear), and the 8259 is masked off
  entirely. IRQ→GSI is a *firmware fact* — the ISO table must be
  honored (i440fx puts IRQ0 at pin 2; assuming irq==gsi loses the
  timer), and polarity/trigger come from the ISO flags, not from
  guesses. Without an IOAPIC the PIC arm stands as the fallback.
- 0x30–0x3F: message-signaled — the device *writes* a message naming
  its vector to 0xFEE00000; the EOI goes to the LAPIC's own EOI
  register (0xFEE000B0), never to the PIC.

All three land on the same stub table and `irq_exc_dispatch`; the
EOI arm consults the line's *route state* (`gsiFor`/`isLapic`), not
the vector range alone — a provider unmasking IRQ1 never learns
which mechanism carried it. A stray MSI vector prints
`irq: stray msi vec=` — unclaimed deliveries are loud, same
doctrine as unmasked PIC lines.

Device waits park on a **kind**, not on a device. `koru_blk_sleep`
was a per-provider extern shaped like a seam; `koru_dev_sleep(kind)`
takes the WaitKind selector (0=blk, 1=gpu) and `wakeKind` resumes
whoever parked on that kind — the next device adds an enum arm, not
an exported symbol, not a new extern. Outside a live sched epoch the
call returns 0 and the caller keeps its bounded cli/hlt loop — the
park is real only when there is a roster to yield to.

The oracle lesson of the rung: MSI-X's first delivery proved the
*doorbell* before any data flowed — `irq: vgpu msix delivered`
printed while `GET_DISPLAY_INFO` still hung, which isolated the bug
to the ring layout (CC_QUEUE_USED wants the Used **struct base**;
programming it with the idx-field address writes idx's real updates
two bytes past where the driver reads). A delivery that arrives
early is evidence the vector/arming side is right — look at the
ring when the doorbell rings but the food never lands.

Measured: `vgpu: cmds=6 msix=6` — six ctrlq commands, six LAPIC
deliveries, zero PIC involvement; `irq-wake` (virtio-blk INTx parks)
unchanged at reqs=980 parks=350 irqs=973. Gates: boot 43/43,
realize 13/13, hosted 43/43.

Evolved 2026-10 (ioapic rung): the legacy block is IOAPIC-delivered,
PIC masked off — `irq0 -> gsi2 edge-high` (ISO remap), `irq9/irq11 ->
level-low` (PCI flags), `pin2 unmasked` on the provider's unmask
verb; timer/kbd/mouse/virtio/sched rows all green through the LAPIC
door at boot 58/58.
