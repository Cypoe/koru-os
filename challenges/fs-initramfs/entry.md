---
name: fs-initramfs
iface: koruos/fs.initramfs
arms: [koru-native]
lane: koru-lift
needs: [module-transport]
accept: gate row iso-initramfs — cpio -> RAM ChildFsOps -> 5 resolved paths
tier: qemu
status: landed
evidence: M
peer: —
provenance: original .kz provider (koruos/initramfs); cpio-newc only
---

# fs-initramfs

cpio-newc archive off an mb2 module, parsed (never copied) into a
RAM-backed `ChildFsOps` view: file bytes alias the reserved module
pages, hardlinks dedup to one ino, symlinks resolve at open (absolute
and `..`-relative through synthesized parents), mutations refuse
`-EROFS`. The storage-independent userland path.

## Acceptance

Gate row `iso-initramfs`: child `/bin/fsread` resolves five paths
through the scoped view (plain, abs symlink, rel symlink through
synthesized `/etc`, hardlink alias, synthesized dir), status=0.

## Notes

- `070702` CRC archives refuse by name — checksums are not ignorable.
- Missing parent dirs synthesize mode 040755; explicit entries win.
