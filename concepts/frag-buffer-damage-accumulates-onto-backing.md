---
type: belief
id: frag-buffer-damage-accumulates-onto-backing
provenance: koru-os native session — wlrcomp nested-compositor rung, 2026-10
ts: 2026-10-31
tags: [wayland, compositor, damage, oracle-lesson, shm, swapchain]
---

**`wl_surface.damage_buffer` is the buffer's freshness contract — the
compositor accumulates, never replaces.** wlroots (and every real client
library) renders through a swapchain *ring*: each frame attaches a
different shm buffer, and only the damaged region of that buffer is
fresh — the rest is whatever that slot held N frames ago. A compositor
that blits the whole attached buffer copies the ring's stale tail over
its scene. Measured, not theorized: wlserver's whole-buffer blit turned
a 1280x720 wlrcomp frame into ~60% zeros on scanout — the undamaged
band of the freshly-cycled swapchain slot — while wlroots' own
`wlr_damage_ring` declared the correct rects all along (first bg commit
`1280x720@0,0`, the inner client's view commit `64x64@0,0`).

The honest seam keeps *two* accumulations honest at once:

- the compositor unions pending damage per commit cycle, blits only
  that rect into retained backing, and presents the same rect — empty
  damage means "nothing changed", not "attach ignored";
- a client that declares no damage at all falls back to whole-buffer
  (the legacy `wl_surface.damage` semantics) — real clients always
  declare, so the fallback only serves fixtures that forgot.

Held consequence — this is the same contract as weston's shm path
(commit copies, damage decides what), one level down: **the surface
backing is accumulated state across buffer identities**, not a window
onto the latest attach. Where `frag-surface-is-commit-plus-repaint-demand`
rules the client-facing surface (present/expose), this rules the
compositor-facing buffer (attach/damage). `WLSRV surf ... dmg=WxH@x,y
blit present` is now the evidence line — a whole-buffer blit on a
partial-damage commit is the bug, not a shortcut.
