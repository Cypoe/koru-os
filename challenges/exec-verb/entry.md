---
name: exec-verb
iface: koruos/proc.exec
arms: [koru-native]
lane: native-zig
needs: [sessions-jobctl]
accept: a musl child execve()s a second image in place — pid/bag/fd table survive, argv/env fresh
tier: qemu
status: open
evidence: —
peer: —
provenance: —
---

# exec-verb

`execve` (nr59): the calling child's address space is replaced by the
named image — pid, session, pgrp, rights bag, and the fd projection
survive the swap; argv/env land fresh. Today spawn is fused
(fork+exec+wait in one verb) so a musl child's `execve()` has no arm.

## Acceptance

A musl child `execl`s `/bin/stage2`; serial shows stage2's own argv/
getpid inheriting pid N, and an fd opened before the swap is still
readable after it (CLOEXEC edges honest). status=0.

## Notes

- Needed by `subprocess`/os.execv (py-cpython-child), real shells
  (busybox-sh-pty), and any exec-shaped userspace.
- The swap is the hard half: tear down mappings except the preserved
  projection, re-load the image through the caller's fs view, rebuild
  the stack with new argv/env — all under the same bag.
