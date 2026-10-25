---
type: belief
id: frag-pin-resolves-provider-by-table-walk
provenance: koru-os native session — exec(nid) rung, 2026-10
ts: 2026-10-25
tags: [native, hosted, nid, ext2, spawn, provider, lifecycle, contract]
---

`exec(nid)` — surfaced as `ext2:exec-by-nid` — resolves its provider by
**walking tables**, never by holding an ambient fs or inferring one from
key bits. The walk is two lookups:

1. **nid → (foreign name, key)** in koruos/nid's object-pin store. The
   pin now yields its foreign name on demand (`koruos_nid_obj_foreign`,
   native + hosted) — the key alone (`dev<<32|ino`) was never enough,
   because the scheme is what names *which lift* serves the object.
2. **foreign scheme → provider lift → mounted registry.** `ext2/…`
   selects this lift; `dev` indexes its `mounted[]` table to a live
   `*Fs`. mount registers on success, unmount deregisters *before* free.

Every miss is a named refusal, not a fallback: unbound nid ("nid not
bound to an object"), unreadable foreign name, wrong scheme ("nid pins
a scheme this provider does not serve" — a `vfat/d0/<ino>` pin will
never route into ext2 by dev-number coincidence), and **a pin that
outlives its mount** ("nid's provider is not mounted"). The pin is
durable; the provider is not — a stale pin refuses, never dereferences
a dead `*Fs`.

The ops-lifetime tightening this forced: the child's fs-view record
(`ChildFsOps`) lives **inside the mounted `Fs`** — built once at mount,
`&fs.vfs` is what every spawn hands the child's address space. The old
shape built it stack-local at each exec call site: safe only while exec
stays synchronous, and an accident the moment a spawn outlives its call
frame. Mount-owned storage makes the lifetime *stated*, not assumed:
the view dies exactly when the provider does, and the table-walk
refusal is what guarantees no child is ever spawned onto a view whose
provider is already gone.

`exec-nid(fs, nid)` remains the caller-held-fs variant — both verbs
converge on `&fs.vfs`; exec-by-nid just walks to the same `*Fs` the
caller would have handed in. When a second provider lift lands, its
scheme prefix and its own `mounted[]` plug into the same walk — the nid
store stays provider-agnostic.

Measured: `boot_ext2` runs `pin → exec-by-nid → exec-nid → unmount →
exec-by-nid(stale)` — serial shows `exec-bynid dev=0 ino=N status=43`
(child actually ran through the resolved mount) and
`exec-bynid post-unmount refused: nid's provider is not mounted`.
Hosted arm repeats it through fork+execve: child ran 3× (path, by-nid,
by-nid-with-fs) + the stale refusal. Gates: boot 32/32, realize 13/13,
hosted 43/43.
