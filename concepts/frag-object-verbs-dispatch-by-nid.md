---
type: belief
id: frag-object-verbs-dispatch-by-nid
provenance: koru-os native session — fs.object rung, 2026-10
ts: 2026-10-26
tags: [native, nid, ext2, syscall, object-axis, grant]
---

A nid is a **callable identity**, not just an exec target. The object
axis now has a verb surface at both tiers, all of it dispatched through
one factored walk (`resolvePin`: nid → key+foreign → scheme → mounted
registry → live `*Fs` — the exec-by-nid walk, generalized):

- **Koru tier**: `ext2:obj-stat/obj-read/obj-write` take a nid and act
  on the inode — no path exists anywhere in the call. Measured
  post-rename: `obj-stat` answers the same ino, `obj-read` returns the
  ELF magic by identity.
- **Syscall tier**: `nr514 openobj(key, flags)` — koru's own ABI verb —
  mints an fs fd by object key, folding to cap 2. `cfOpenKey` opens by
  inode (dev-checked: another provider's key is `EXDEV`, a freed inode
  `ENOENT`, a directory `EISDIR`).

The consequence that makes this the strongest form of the grant
ruling: **for an object-grant child, the grant check IS the syscall's
argument**. `objt.elf` runs with the open class bit removed and a
`{cap:2, obj:key, R|W}` grant — `openobj(key)` reads and writes without
ever naming a path, and `openobj(otherkey)` refuses `EACCES` with the
seam naming the object. There is no projection to resolve and check
after the fact: the name in the syscall and the name in the grant are
the same keyspace.

Named open cells: `O_CREAT` under openobj refuses `ENOSYS` — identity
cannot mint a directory entry; creation stays a path verb. And the
`koruos/fs.object` *iface lift* is deferred on purpose: factoring an
interface declaration over one provider is speculative abstraction —
when a second fs provider lands, the ops record is already
object-keyed and the iface names itself.
