---
name: ptmx-devpts
iface: koruos/dev.pts
arms: [koru-native]
lane: native-zig
needs: [pty-termios]
accept: open("/dev/ptmx")+ptsname("/dev/pts/N") through the scoped fs view
tier: qemu
status: open
evidence: —
peer: —
provenance: —
---

# ptmx-devpts

The filesystem view over the pty channel: `/dev/ptmx` open mints a pair
(nr521 underneath), `/dev/pts/N` names the slave, TIOCGPTN/TIOCSPTLCK
drive musl's `posix_openpt`/`ptsname`/`unlockpt` unchanged. What makes
pty look like POSIX instead of a door number.

## Acceptance

A musl child calls the real `posix_openpt`+`unlockpt`+`ptsname`+`open`
sequence through its scoped fs view — no nr521, no KORU_DOOR — and the
pair behaves identically to the pty-termios gate child.

## Notes

- devpts is a synthetic fs provider (like initramfs, but kernel-backed
  entries); mounting it into a child's view is the spawn-side question.
- `locked` state already exists on the pair (TIOCSPTLCK honored).
