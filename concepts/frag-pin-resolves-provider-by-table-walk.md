---
type: belief
id: frag-pin-resolves-provider-by-table-walk
provenance: koru-os native session — exec(nid) rung, 2026-10; pin-rows rung, 2026-10
ts: 2026-10-26
tags: [native, hosted, nid, ext2, spawn, provider, lifecycle, contract]
---

`exec(nid)` — surfaced as `ext2:exec-by-nid` — resolves its provider by
**walking tables**, never by holding an ambient fs or inferring one from
key bits. The walk is three lookups over three *separate lifetimes*:

1. **nid → (foreign name, key)** in koruos/nid's object-pin store —
   the *durable identity*. `koruos_nid_obj_foreign` yields the foreign
   name on demand; the key alone (`dev<<32|ino`) was never enough,
   because the scheme is what names *which lift* serves the object.
   This table never forgets: identity outlives mounts.
2. **nid → live pin row** — the *lease*. `pin` mints a `{nid, gen,
   live}` row stamped with the mount's generation; `unpin` kills it.
   This is the ruling the pin-rows rung landed: **identity and binding
   are different objects with different deaths.** The store answering
   "what object does this nid name" is not proof that a live binding
   exists to dispatch on it.
3. **foreign scheme → provider lift → mounted registry.** `ext2/…`
   selects this lift; `dev` indexes its `mounted[]` table to a live
   `*Fs`. mount registers on success, unmount deregisters *before*
   free.

Every miss is a named refusal, not a fallback: unbound nid, unreadable
foreign name, wrong scheme, **a pin that outlives its mount**
("nid's provider is not mounted"), **an evicted row** ("pin's row
evicted — the identity outlived the lease"), and **a stale row**
("stale pin — mount generation moved (re-pin to re-lease)").

The generation ruling: each `mount` bumps a provider epoch and stamps
its `*Fs`. A remount *cannot prove* it's the same image — so a row
minted under the old epoch refuses at use. Resurrection exists only
through **re-pin**: re-pinning the same object re-mints the same
deterministic nid and re-leases its row at the new generation — honest,
because the identity IS the same object. Silent resurrection through
remount is what the generation check exists to refuse. A full pin
table refuses at pin time by name — pins are released by `unpin`,
never silently evicted.

`resolvePin` and `exec-nid` both pass the row check — every
nid-dispatched verb (exec-by-nid, obj-stat/read/write, and whatever
the second provider adds) shares the same lease gate. The row check
comes *after* the durable-store and registry lookups: a stale pin
still knows exactly what it names; it just may not dispatch.

The ops-lifetime tightening this forced still holds: the child's
fs-view record (`ChildFsOps`) lives **inside the mounted `Fs`** —
built once at mount, `&fs.vfs` is what every spawn hands the child's
address space. Mount-owned storage makes the lifetime *stated*, not
assumed: the view dies exactly when the provider does, and the
table-walk refusal is what guarantees no child is ever spawned onto
a view whose provider is already gone.

`exec-nid(fs, nid)` remains the caller-held-fs variant — both verbs
converge on `&fs.vfs` and the same row check. When a second provider
lift lands, its scheme prefix and its own `mounted[]` plug into the
same walk — and the pin-row table stays provider-agnostic like the
nid store does (rows key on nid+generation, not on `*Fs`).

Measured: `boot_ext2` runs pin → rename → exec-by-nid → unmount →
mount → exec-by-nid(stale → "mount generation moved") → re-pin
(same nid `a79c9b5b54363213`) → exec-by-nid (status=43, ino=12) →
unpin → exec-by-nid ("row evicted"). Gates: boot 38/38, realize
13/13, hosted 43/43.
