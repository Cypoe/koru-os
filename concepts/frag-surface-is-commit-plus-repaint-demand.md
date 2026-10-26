---
type: belief
id: frag-surface-is-commit-plus-repaint-demand
provenance: koru-os hosted session — X11 oracle + painter fixture, 2026-10
ts: 2026-10-24
tags: [surface, compositor, oracle-lesson]
---

A surface's contract has **bidirectional** damage. Measured, not theorized:

- client→server: `present(x,y,w,h)` commits only the repainted rect;
  an empty rect refuses — commit *means* damage.
- server→client: the `expose` event is a repaint *demand*. Pixels presented
  before the window is viewable get wiped by the server's background repaint
  (observed on WSLg: early presents read back 0x000000; post-map presents
  stick). The honest response is not a delay or a flag — it is honoring the
  demand event and repainting the scene.

Corollary for `nativeCompositor`: a surface is not "write and show" — it is
"hold a scene and repaint on demand". A compositor or client that cannot
receive invalidation is a renderer, not a surface user. Pair-release
(window object + backing store die together) stays part of the contract —
the bridge discharge's shape.

The ruling now reaches the bare seam: `koruos/fb` gained `present(x,y,w,h)`
as an explicit verb, because **draw and commit were always distinct — the
LFB just hid it**. On BGA an LFB write is already "on" the display; on
virtio-gpu the CPU writes a backing store the device cannot see, and commit
is literally two commands — TRANSFER_TO_HOST_2D uploads the damaged rect to
the host resource, RESOURCE_FLUSH pushes it to the scanout. The fb seam's
backend dispatch (mb2 LFB → virtio-gpu → BGA) is a provider-internal
ranking over what the table offered; the caller's verbs don't change.
Measured: `-vga none -device virtio-gpu-pci` boots `backend=vgpu`, six
commands retire through MSI-X, and the monitor screendump reads
ff0000/00ff00/0000ff off the scanout — pixels as machine evidence, not
self-report.

`koruos/surface` now binds `koru-native` (surf.zig + comp.zig): a pool
of provider-owned contiguous-frame backings, open mints `*Surf<open!>`
and attaches the cleared backing into the compositor's layer stack,
present(damage) forwards to `comp.damage`, close detaches (the vacated
rect repaints from the retained backings beneath) then pair-releases
buffer + handle through pmm.freeBlock. Placement is still provider
policy — a fixed anchor, no move verb yet — but the cascade and
painter's-order bounds this paragraph once named are discharged:
`nativeCompositor` landed and the z-rule now lives in
frag-scene-owns-stacking.

The oracle lesson this rung paid for: **serial self-report passed while
the pixels were wrong.** boot_surf printed SURF COMPLETE with every
sub-rect doubled-offset on the scanout — the device obeyed the command,
the command carried the wrong offset (virtio TRANSFER_TO_HOST_2D's
`offset` is the byte offset of the rect's top-left *in the strided
backing* — `y*stride + x*bpp` — not "this rect's data start"; a
full-frame transfer hides the bug at offset 0). The screendump caught
what eight green serial lines could not. Gate rule that follows:
for anything that paints, the row is the pixel readback — the seam's
own "ok" is not evidence of where the pixels went.
