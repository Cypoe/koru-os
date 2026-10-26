---
type: belief
id: frag-irq-is-a-doorbell-not-a-classifier
provenance: koru-os native session — PS/2 aux-channel mouse rung, 2026-10
ts: 2026-10-26
tags: [native, input, 8042, irq, drivers, contract]
---

The 8042 is **two devices on one controller**, and an IRQ line is a
doorbell, not a byte classifier. The byte's owner is named by status
bit5 (AUX), not by the vector that rang:

- An aux byte pending during IRQ1 belongs to the mouse's packet
  assembler — the kbd's IRQ handler routes it, it doesn't claim it.
- A kbd byte pending during IRQ12 is a scancode — the aux handler
  routes it to the kbd, not to a half-eaten mouse packet.
- A *controller reply* (CCB read, ACK to a controller command) is a
  kbd-class byte and raises IRQ1 — replies ride the device channel,
  they are not a third channel.

Every drain site — IRQ1, IRQ12, the seam's drain-on-poll — reads
status before data and routes by bit5. The flag is the fact; the
vector only says "something arrived".

The oracle lesson of the rung: the aux handshake read CCB through a
polled `waitOut` while IRQ1 was armed — QEMU raised IRQ1 for the
reply byte (real i8042 semantics), `kbd.irq` consumed it correctly
by its own rules, and the polled read starved forever. The fix is
i8042 discipline, not a workaround: **command sequences over a
shared output buffer run `cli`** — the byte still latches in OBF,
but no armed handler can steal it mid-wait. Every refuse path
re-arms via `defer sti()`. If your poll and an interrupt can both
read the same port, the poll loses — mask the interrupt, don't
hope the race goes your way.

Device-side facts this rung fixed at the seam: IRQ12 = vec 0x2C on
the slave PIC (was previously a masked stray — an unclaimed doorbell
is loud by doctrine); PS/2 packets are 3-byte frames synced on
byte0's bit3 with desync counted, not absorbed; motion arrives as
device deltas — pointer position stays compositor-owned per the
iface's standing ruling; button *edges* are computed by diffing
packet-reported state, and codes come out X-style (1=L,2=M,3=R) so
both arms' callers see one vocabulary.

Measured: `mouse: PS/2 aux online, IRQ12 unmasked`; QEMU monitor
`mouse_move 40 30` + `mouse_button 1` produced
`MOUSE PTR dx=40 dy=-30 btn=1` — motion deltas and the press edge
rode `koruos_input_poll` end to end. Gates: boot 46/46,
realize 13/13, hosted 43/43.
