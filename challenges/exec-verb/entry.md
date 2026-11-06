---
name: exec-verb
iface: koruos/proc.exec
arms: [koru-native]
lane: native-zig
needs: [sessions-jobctl]
accept: a musl child execve()s a second image in place — pid/bag/fd table survive, argv/env fresh
tier: qemu
status: landed
evidence: V
peer: —
provenance: —
---

# exec-verb

`execve` (nr59): the calling child's address space is replaced by the
named image — pid, session, pgrp, rights bag, and the fd projection
survive the swap; argv/env land fresh. Spawn was fused
(fork+exec+wait in one verb) so a musl child's `execve()` had no arm.

## Acceptance — MET (QEMU serial)

`boot_exec` → cpio `/bin/exec` + `/marker.txt`. Stage 1 opens a marker
fd (dup'd to 7), marshals its own pid/pgrp/sid into argv, execl()s
ITSELF. Stage 2 verifies the contract as data: `argv-swap`,
`pid-survives`, `pgrp-survives`, `sid-survives`, `fd-survives`
(the 'K' byte read post-swap), `bag-survives` (openpty still
EACCES). `EX COMPLETE fails=0`, status=0.

## Notes

- Order is load-bearing: argv/env marshal into kernel blobs BEFORE
  the address-space teardown (the user pages carrying them die);
  a header sanity read refuses bad targets pre-burn — the image
  stays alive on ENOENT/ENOEXEC like linux's pre-point-of-no-return.
- Post-teardown failure is `childDie` — linux kills the process past
  the point of no return too.
- `canonNr: 59 => 57` — nr59's own bit is the scene class; the image
  swap is the create family's rebirth.
- No CLOEXEC tracking on this arm — all fds survive (the honest
  POSIX-subset statement; tracked when a consumer asks).
- Unblocks `subprocess`/os.execv (py-cpython-child) and real shells.
