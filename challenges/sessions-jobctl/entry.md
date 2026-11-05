---
name: sessions-jobctl
iface: koruos/proc.session
arms: [koru-native]
lane: native-zig
needs: [pty-termios]
accept: setsid/setpgid/tcsetpgrp; ^Z stops, fg/bg switch fg pgrp, TTIN/TTOU, signal death
tier: qemu
status: landed
evidence: V
peer: —
provenance: —
---

# sessions-jobctl

Process groups, sessions, controlling terminal: `setsid`/`setpgid`/
`getsid`/`getpgid`/`kill` syscalls, `TIOCSCTTY`/`TIOCGPGRP`/
`TIOCSPGRP`/`TIOCNOTTY` ioctls, foreground-vs-background IO
(SIGTTIN on read, SIGTTOU on write-side config verbs), orphaned-pgrp
stop suppression, `^Z` -> SIGTSTP -> WUNTRACED `0x7f` report,
`^C` -> signal death -> WIFSIGNALED reap.

## Acceptance

`jobctl.c` musl child: fork under pid-1 (init-shaped: a pgrp leader
cannot setsid — measured, not assumed), setsid -> openpty ->
TIOCSCTTY -> per-job fork+setpgid+TIOCSPGRP, `^Z` through the master
stops the fg pgrp (WUNTRACED reports signo 20), `kill(-pg,SIGCONT)`
resumes it (exit 7 reaped), `^C` kills the fg job by SIGINT
(WIFSIGNALED, termsig 2), a background reader stops on SIGTTIN
(signo 21), `kill(-dead-pgrp)` answers ESRCH. Same source is the
linux twin under WSL — 37 checks, identical expectations both arms.

## Landed 2026-11-10

- `Child` carries `pgid`/`sid`/`ctty`/`stopped`/`stop_signo`/
  `sig_ign`/`sig_caught`/`exit_signo`; `Pty` carries `fg_pgrp`.
- `rt_sigaction` now stores dispositions — a fact the kernel owns:
  default stop-class stops the child, CONT resumes + un-parks blocked
  syscalls (restarted-syscall shape), terminate reaps through the
  same `childDie` path exit uses. Handlers queue the fact only.
- `sigSend` is the disposition engine; `kill` (nr62) does pid/pgrp/
  broadcast targeting incl. negative-pgid.
- `wait4` learns WNOHANG/WUNTRACED/pgrp waits and reports stops as
  `0x7f|signo<<8`, signal deaths as the raw signo.
- `ptyCheckTTOU` mirrors `tty_check_change`: ignored/blocked TTOU
  proceeds (the shell's reclaim), orphaned callers get EIO, the rest
  stop and re-question on CONT.
- `fgSweep` clears a dead pgrp's foreground claim on reap — a pgrp
  is an identity, and slot reuse must never alias a stranger into
  the foreground (measured: pid 3 aliased and skipped TTIN).
- ISIG/SIGWINCH route to `fg_pgrp`; `owner` stays the pre-session
  fallback.
- canonNr: pipe2(293) folds to the channel class; setpgid/getpgid/
  setsid/getsid/kill live in proc-metadata cap 62; fork/wait keep
  their own bits — the fixture's bag proves every fold.

## Notes

- The linux twin measured two model edges: pid-1 cannot setsid (our
  first exec'd child IS init-shaped — the suite runs in a fork), and
  WSL1 hangs a pty up when the fg pgrp dies (the driver's between-jobs
  TIOCSPGRP reclaim is what real shells do anyway).
- `TIOCNOTTY` and SIGHUP hangup on session-leader death are
  implemented (`cttyHangup`) but not yet asserted by the fixture —
  the fixture ignores SIGHUP like a real shell does.
