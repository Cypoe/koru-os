---
name: readdir-verb
iface: koruos/fs.readdir
arms: [koru-native, hosted]
lane: koru-lift
needs: []
accept: getdents64 through ChildFsOps on initramfs + ext2 providers
tier: qemu
status: open
evidence: —
peer: —
provenance: —
---

# readdir-verb

`ChildFsOps` has 17 verbs and no readdir — directory *listing* is the
named ABI gap (stat/open/read work; `ls` cannot). Adding the verb means
touching the ABI record, every provider (ext2, initramfs, future devpts
+ tmpfs), and the syscall arm (getdents64 nr217).

## Acceptance

A child runs `getdents64` on a scoped view: initramfs dir lists its
entries including synthesized parents; ext2 lists real dirents. ABI
version bump handled so old providers refuse by name, not by shape.

## Notes

- The kernel-side question is shape, not content: one-entry-per-call
  vs buffer-fill — linux's buffer-fill is what musl readdir wraps.
