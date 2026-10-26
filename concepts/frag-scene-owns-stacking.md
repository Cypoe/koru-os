---
type: belief
id: frag-scene-owns-stacking
provenance: koru-os native session — comp.zig + boot_comp.kz + screendump oracle, 2026-10
ts: 2026-10-26
tags: [compositor, surface, pointer, oracle-lesson]
---

The scene owns stacking; the seam owns custody. Measured, not theorized:

- **z is scene state, not present order.** `comp.zig` keeps a layer stack;
  `present` submits damage into it, `attach`/`detach` reshape it, and the
  composite walks z — never arrival order. `boot_comp` proves it the hard
  way: the LOWER surface presents *after* the upper is already mapped and
  filled, and the scanout still reads the upper's cyan on top. Cascade
  placement and painter's-order-at-present are dead as the z-rule —
  placement stays provider policy (a fixed anchor — no move verb yet) but
  pixels answer to the stack.
- **close repaints what it exposed.** Detach damages the vacated rect and
  the composite repaints it from the retained backings beneath — magenta
  underlay read back on the scanout with no client verb involved. Reveal
  is server work; the retained-mode contract
  (frag-surface-is-commit-plus-repaint-demand) made the backing durable
  precisely so the server could do this.
- **pointer position is compositor state.** The input seam carries raw
  deltas — `koruos_input_poll` fans `motion{dx,dy}` to `comp.feedMotion`
  while still returning the event to the client (fan-out, not capture).
  Position clamps to the frame; the cursor is the topmost composite-time
  layer, revealed on first motion — never rendered before a delta exists.
  The 51x48 damage print (`nb=67`) and the 67 non-bg cursor pixels on the
  scanout are the same fact counted from two sides.

Oracle lesson — *the monitor starves behind a spinning guest*: on TCG a
tight guest loop leaves QEMU's main loop no VCPU-yield points, so monitor
commands (screendump, mouse_move) queue until the program exits — every
dump then reads the post-detach black frame and a green serial line hides
a black surface. The fixture's holds must be `hlt`-paced (PIT wakes them);
the guest idling is also just the correct idle posture. Same family:
`-serial file:` buffers writes on Windows QEMU — `stdio` or TCP serial
streams live; marker-driven tooling that greps a `file:` chardev sees the
world a whole program behind.
