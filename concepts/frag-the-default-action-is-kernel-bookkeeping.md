---
type: belief
id: frag-the-default-action-is-kernel-bookkeeping
provenance: koru-os native session — sessions-jobctl rung, 2026-11
ts: 2026-11-10
tags: [native, signals, sessions, job-control, dispositions, facts]
---

**A signal disposition is kernel-owned bookkeeping on the fact
stream — not a user invocation the kernel must honor.** The facts
doctrine survives job control intact because the default action
belongs to the same class as reaping and wait-status: accounting
the kernel keeps *about* the process, not work the kernel performs
*for* it. `sigSend` queues the fact first, then the kernel's own
table decides the lifecycle effect:

- **stop-class** (TSTP/TTIN/TTOU/STOP) sets `stopped` and records
  `stop_signo` for the WUNTRACED `0x7f` report — the scheduler's
  `nextRunnable` simply declines to choose a stopped child, so a
  stop is a roster fact, not a context switch.
- **CONT** clears the stop *and un-parks a blocked syscall* — the
  kblock continuation re-questions its wait, which is exactly
  linux's `ERESTARTSYS` shape: a still-background reader re-takes
  SIGTTIN and re-stops, no special restart register needed.
- **terminate** runs the same `childDie` the exit arm uses — a
  signal death is a status transition, and `wait` reads it as the
  raw signo (`WIFSIGNALED`) while `CLD_KILLED` rides to the
  parent's queue.
- **ignored/blocked/caught** are `sig_ign`/`sig_caught`/`sig_blocked`
  bits `rt_sigaction` now actually stores — a registered handler
  fires *never*, which is honest: the queued fact is the only
  deliverable our model promises, and signalfd already consumes it.

The ordering in `tty_check_change` is the subtle part and linux's
own table is the spec: **an ignored or blocked SIGTTOU lets a
background `TIOCSPGRP` proceed** (that is literally how a shell
reclaims its terminal between jobs), an orphaned caller answers
EIO, and only the unprotected caller stops. Checking orphaned
*before* the ignore bit inverted the table and EIO'd every
foreground reclaim — the twin's `signal(SIGTTOU, SIG_IGN)` exists
because real shells live on the ignored-proceeds edge.

Consequences held at measurement time: `setsid` from a pgrp leader
EPERMs (pid 1 is init-shaped and cannot start a session — the test
forks, like linux init's children do); a stopped child still owns
its slot, fds, and queued facts; and the parent's `SIGCHLD` queue
carries `CLD_STOPPED`/`CLD_CONTINUED`/`CLD_KILLED` with the signo
and pid as data.
