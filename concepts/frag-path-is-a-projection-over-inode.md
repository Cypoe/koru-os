---
type: belief
id: frag-path-is-a-projection-over-inode
provenance: koru-os native session — writable-fs + rename rung, 2026-10
ts: 2026-10-26
tags: [native, ext2, rename, nid, identity, grants, oracle]
---

**A path is a view; the inode is the identity.** ext2's `rename`
mutates directory entries only — the inode a pin bound is never
touched, so `(dev<<32|ino)` keys and the nids minted from them survive
the view mutation by construction. Measured, not asserted:
`boot_ext2.k` runs `pin(child.elf) → rename → lookup(moved.elf) →
exec-by-nid(nid)` — the post-rename exec resolves the same ino
(`status=43`), the stale `child.elf` path refuses `path not found`,
and the host-side debugfs check after QEMU exits finds `moved.elf`
sitting on the pin's inode. Identity-outlives-view is now a gate row.

The writable view this rung opened is bounded and every bound is a
named refusal, not a silent edge:

- `write`/`writev` on `.fs` fds write through `writeSpan` — the
  shared growth engine over `blkAtAlloc` (direct → single → double
  indirect, ~66 MiB of file span; triple-indirect is `-ENOSPC` by
  name). Missing tables allocate and hit disk immediately (an
  indirect block owns its pointers the moment it exists), fresh data
  blocks zero-fill — a newly allocated block's stale bytes are not
  file content — partial EXISTING blocks read-modify-write, and a
  partial write still folds `i_size`/`i_blocks` back so on-disk
  pointers match the bytes written. Measured: 40 KiB in one write
  crosses `(IND)`, a sparse write at 300 KiB crosses `(DIND)`, and
  host debugfs lists both tables on disk after QEMU exits.
- `unlink` frees the inode + the whole mapped span — direct,
  single-indirect, and each double-indirect leaf table plus its
  root. O_TRUNC rides the same walk.
- `rename` serves both musl spellings (nr316 `renameat2` flags=0 →
  nr264 `renameat` fallback → nr82), replaces a regular-file
  destination POSIX-style, refuses a directory destination.
- `creat(85)`, rename family, `unlink`/`unlinkat` all fold to the
  fs-object class (cap 2) — the class bit means mount-wide, and object
  grants narrow with the W verb: **the mutated object is always a
  directory** for path-mutation arms, the file itself for write-open
  and O_TRUNC.
- `mkfile` shares create's allocation machinery (inode bitmap scan,
  dir-entry insert, bgd+sb counters); `dirAdd`/`dirRemove` work any
  directory inode — slack-split inserts, predecessor-merge removes.
- `.`/`..` cost zero code — `dirFind` resolves the on-disk entries
  like any name (`/bin/../hello.txt` opens). No path parser ever
  special-cases them.

**Oracle lesson — writev is not write.** The first green-looking
write run returned `rb=0`: musl's `fwrite`/`fclose` emit **writev(2)**,
and the nr20 arm was a serial sink with no kind dispatch — the bytes
printed to console while the file stayed size 0. Any arm that bypasses
kind dispatch is a silent I/O redirect; writev now dispatches per-iov
on the same kind table as write. Check the syscall you think musl sends
against the one it actually sends — disassembly or strace-shaped
serial evidence, never assumption.
