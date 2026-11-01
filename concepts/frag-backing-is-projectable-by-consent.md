---
type: belief
id: frag-backing-is-projectable-by-consent
provenance: koru-os native session — mmap'd *Surf rung, 2026-11
ts: 2026-11-01
tags: [native, surface, mmap, provider, dma-buf, contract]
---

**A provider's retained backing is projectable by consent, not by
right.** `mmap` on a `.surf` fd asks the provider whether its backing
can live in a client VA (`koruos_surface_map` → `phys`+`bytes`); this
arm's backing is a contiguous pmm block, so the answer is yes and the
mapped pages are the *same frames* the compositor walks at present —
dma-buf semantics in the seam's own terms. A GPU-resident backing on a
future arm returns no, and `K_SURF_BLIT` stays the honest path. The
provider decides; the syscall shape doesn't change.

Two rulings ride on that answer:

- **MAP_SHARED only.** A private map of a scene backing is a copy that
  silently diverges — the same CoW refusal shm already carries
  (`EOPNOTSUPP`), not a subtle lie the caller would never detect.
- **Lifetime follows the pin model.** Each mapped page is `pmm.pin`'d
  — a map that outlives `close(fd)` keeps the frames alive but
  orphaned (the layer is already detached); the exit walk drops refs
  exactly like shm's. No extra refcount, no special case.

Held consequence — this is the dumb-buffer-mmap precedent: wlroots'
DRM backend's `mmap(dumb_bo)` is the same ask ("project my scanout
memory"), so when a DRM-shaped provider arrives its map verb is
already written — the question it must answer is the same one this
frag records.
