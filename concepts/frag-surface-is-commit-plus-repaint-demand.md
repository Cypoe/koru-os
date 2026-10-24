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
