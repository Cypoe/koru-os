---
type: belief
id: frag-shm-size-is-a-declaration
provenance: koru-os native session — Debian foot 1.28 over wlserver, 2026-11
ts: 2026-11-16
tags: [native, shm, mmap, wayland, oracle, contract]
---

**A shm object's size is a declaration of intent, not an allocation.**
Debian foot `ftruncate`s its wl_shm pool memfd to 0x20000000 — 512 MiB,
a capacity ceiling — on startup, then maps and touches the scrollback
slices it actually renders. Eager-backing the size is unbootable: the
object wants half the guest's RAM and uses almost none of it. The
ruling the oracle forced: `ftruncate`/`size` names the object's
*extent*; frames mint on first touch (write or page-fault through a
map), and `mmap` bounds check against extent, not against minted
frames.

Held consequence — seals still gate the extent, not the backing.
`F_SEAL_SHRINK|F_SEAL_GROW` constrain the declared size; a lazy object
under seals is still sealable because the seal speaks about the
extent field, not about pages that may never exist. foot's
`F_ADD_SEALS` + map-in-slices pattern works unchanged.

This is the same shape as `frag-backing-is-projectable-by-consent`:
the seam answers the contract question (extent, seals, projectability)
and defers the resource question (which frames) to the moment it's
actually asked.
