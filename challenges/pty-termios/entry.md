---
name: pty-termios
iface: koruos/chan.pty
arms: [koru-native]
lane: native-zig
needs: []
accept: gate row pty-termios — 47 child-side checks through a tight bag
tier: qemu
status: landed
evidence: M
peer: —
provenance: original; oracle = same-source linux twin (ptytest.c posix_openpt)
---

# pty-termios

The terminal primitive: nr521 openpty mints a kernel-backed
master/slave pair with full n_tty-shaped line discipline — canonical
echo/erase/kill, ISIG queuing signal facts on the owner, TIOCSWINSZ ->
SIGWINCH, ICRNL, OPOST|ONLCR, IXON flow, EIO on dead ends, linux
termios ioctl wire (TCGETS/TCSETS*/winsz/ptn/lock/FIONREAD).

## Acceptance

Gate row `pty-termios`: musl `/bin/ptytest` runs 47 checks through a
tight bag — echo byte shapes asserted, ^C->SIGINT and winsz->SIGWINCH
through real musl signalfd() (nr327 alias), ICRNL/ONLCR transforms,
EIO. status=0.

## Notes

- frag-the-linux-twin-is-the-ldisc-oracle: the twin corrected u32 ioctl
  cmd, uncommitted-echo flush, ECHOKE>ECHOK, blocked-mask signalfd.
- Owner-signal model, no sessions yet — see sessions-jobctl.
