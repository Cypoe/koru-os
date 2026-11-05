---
name: sessions-jobctl
iface: koruos/proc.session
arms: [koru-native]
lane: native-zig
needs: [pty-termios]
accept: setsid/setpgid/tcsetpgrp; ^Z stops, fg/bg switch fg pgrp, orphaned SIGHUP
tier: qemu
status: open
evidence: —
peer: —
provenance: —
---

# sessions-jobctl

Process groups, sessions, controlling terminal: `setsid`/`setpgid`/
`getsid` syscalls, `TIOCGPGRP`/`TIOCSPGRP` ioctls, foreground-vs-
background IO (SIGTTIN/SIGTTOU), orphaned-pgrp SIGHUP+SIGCONT, ^Z ->
SIGTSTP -> job stops. The layer `pty.owner` currently stands in for.

## Acceptance

A fixture child: setsid -> TIOCSCTTY -> fork worker -> setpgid ->
tcsetpgrp; ^Z queues SIGTSTP on the fg pgrp, fg/bg ioctls switch it;
background read queues SIGTTIN; orphan -> SIGHUP. All through real
musl calls, pending-fact model preserved.

## Notes

- The linux twin already measured the no-ctty edge: ISIG does nothing
  without a session (ptytest.c setsid+TIOCSCTTY on linux only).
- WSL SIGHUP'd the twin mid-run — session emulation edges are where
  the twin is least trustworthy; mark those rows C-class.
