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
- 0x20–0x2F: PIC lines — INTx, masked on the 8259, EOI written to
  master+slave ports.
- 0x30–0x3F: message-signaled — the device *writes* a message naming
  its vector to 0xFEE00000; the EOI goes to the LAPIC's own EOI
  register (0xFEE000B0), never to the PIC. The PIC is not consulted
  and must not be EOI'd — two doors, two acknowledgements, one
  dispatch table.

All three lands on the same stub table and `irq_exc_dispatch`; the
dispatch arm branches on vector range, not on device type. A stray
MSI vector prints `irq: stray msi vec=` — unclaimed deliveries are
loud, same doctrine as unmasked PIC lines.

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
