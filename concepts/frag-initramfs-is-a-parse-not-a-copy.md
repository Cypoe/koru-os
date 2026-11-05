---
type: belief
id: frag-initramfs-is-a-parse-not-a-copy
provenance: koru-os native session — initramfs rung, 2026-11
ts: 2026-11-01
tags: [native, fs, initramfs, cpio, ramfs, loader, contract]
---

**Mounting a loader-carried archive is a parse-and-alias, never a
materialization.** `koru/initramfs` reads a cpio-newc stream out of an
mb2 module and builds an inode table whose file `data` pointers
reference the *reserved module pages themselves* — the fs owns the
directory structure, not the bytes. Consequences are contract, not
implementation detail:

- **The view is read-only by construction.** Every mutation verb
  (`write`/`rename`/`unlink`/`mkdir`/`rmdir`/`link`/`mknod`) refuses
  `-EROFS` by name — the backing is loader-owned memory the child was
  never granted, and aliasing means there is no private copy to
  mutate. An initramfs that silently accepted writes would be lying
  about whose pages they are. A writable RAM arm (tmpfs-shaped) is a
  later provider, not a flag on this one.
- **Missing parents are synthesized, not refused.** cpio is a flat
  stream; the fs is a tree. Intermediate directories the archive
  omits materialize as real dir objects (mode 040755), explicit
  entries always win. Strict-unpacker refusal was the alternative;
  synthesis matches what Linux initramfs consumers already assume.
- **Identity survives the container.** Hardlinks dedup to one object
  (same ino, nlink counted); symlinks resolve at open through the
  same path projection as everything else — absolute and `..`
  relative alike. cpio-newc was chosen as the container because it
  is the format every existing initramfs tool already speaks; the
  *view* is the contract, the archive is swappable packaging.

Gate shape: `iso-initramfs` — GRUB `module2` carries `initramfs.cpio`,
the child `/bin/fsread` resolves five paths through the mounted view
(plain file, absolute symlink, `..`-relative symlink through a
synthesized `/etc`, hardlink alias, synthesized parent) and exits 0.
The parent never copies a byte of file data; `pmm`'s reservation is
the only lifetime the bytes have, and that is exactly the lifetime
the fs view needs.
