---
type: belief
id: frag-fs-view-is-scoped-by-spawn
provenance: koru-os native session — fs-in-child rung, 2026-10
ts: 2026-10-24
tags: [native, spawn, ext2, fs, rights, oracle]
---

A ring-3 child's filesystem view is **scoped by the spawn call** — the
fs its image came from hands down an ops record
(`open/read/read_at/seek/stat/close` over opaque provider handles) as
`koru_spawn_elf`'s 4th arg. ext2's `exec`/`exec-nid` pass their own
`Fs`; `spawn:exec`, embedded children, and `hostexec` pass `null`, and
a child without a view gets `open() == -ENOSYS` — never a borrowed fs,
never an ambient root.

The split of custody that makes it honest:

- **The kernel side is fs-agnostic.** `user.zig` owns only fd slots
  3..7, child-memory copies (through the identity map, so write-bit
  and U/S state can't fault the copy), and the bag check — `openat`
  (257) folds to the open capability (2). It never parses a path.
- **The provider owns everything fs-shaped.** Handles
  (`OpenFile{ino,pos}`), `lookupPath` for names, `readAt` for the
  partial read. Path strings are *views* — the read is always
  inode+offset, the same split `fetch`/`exec` already live by.
- **The view is read-only by construction.** `O_WRONLY`/`O_RDWR` get
  `-EROFS` — a property of *this* view (ext2's create-side scope
  stays narrow), not a claim fs writes are forever banned.
- **Handles are opaque ints to the kernel; pointers to the provider.**
  fd slot → `OpenFile*` only inside ext2's own ops — a forged fd just
  misses a slot and is EBADF, not a pointer the kernel trusts.

The rung's oracle lesson — the one a real binary had to expose:

**State a trap mutates must be reloaded before sysret, not at the next
resume.** `arch_prctl(SET_FS)` recorded `c.fsbase` but the MSR was only
rewritten in `resumeChild` — correct only if a tick preempted the child
before its first `%fs:0` read, reloading FS on the way back in. musl's
`puts` survived *by luck* (a PIT tick intervened); fscat's earlier TLS
touch faulted: FS=0 → linear 0 → supervisor page → `err=5`. A green
run on stale-register bugs proves nothing until a program's timing
doesn't save you — the fix writes `FS_BASE` in the prctl path itself.
