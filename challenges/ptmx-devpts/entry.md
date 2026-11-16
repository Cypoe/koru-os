---
name: ptmx-devpts
iface: koruos/dev.pts
arms: [koru-native]
lane: native-zig
needs: [pty-termios]
accept: open("/dev/ptmx")+ptsname("/dev/pts/N") through the scoped fs view
tier: qemu
status: landed
evidence: V
peer: —
provenance: —
---

# ptmx-devpts

The filesystem view over the pty channel: `/dev/ptmx` open mints a pair
(nr521 underneath), `/dev/pts/N` names the slave, TIOCGPTN/TIOCSPTLCK
drive `posix_openpt`/`ptsname`/`unlockpt` unchanged. What makes pty
look like POSIX instead of a door number.

## Acceptance

Met — and by the *harder* client: glibc foot's `posix_openpt` opened
`/dev/ptmx`, `ptsname` returned `/dev/pts/0`, `unlockpt` cleared
TIOCSPTLCK (arg is a userspace pointer, not a value — the oracle
taught that), and the slave child opened `/dev/pts/0` + `TCGETS2` +
`TIOCSCTTY` onto it. The `/dev/pts/0` child then ran a real shell.
Same evidence row: `foot-real` in `scripts/check-boot.sh`.

## Notes

- devpts is served as path doors in the scoped fs view — no mounted
  devpts fs object yet; a real devpts mount is the spawn-side question
  when multi-view isolation lands.
- termios2 (`TCGETS2`/`TCSETS2`/`TCSETSW2`) — glibc's spelling — is
  armed on the slave alongside musl's `TCGETS` family.
