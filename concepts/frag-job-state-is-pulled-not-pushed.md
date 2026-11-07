---
type: belief
id: frag-job-state-is-pulled-not-pushed
provenance: koru-os native session — busybox-sh-pty rung, 2026-11
ts: 2026-11-07
tags: [native, signals, wait4, job-control, stored-metadata]
---

**On the stored-metadata arm, a child's death is a fact the parent
pulls — oracles must assert it through `wait`, not await a
notification.** Ash's SIGCHLD handler is registered metadata that
fires never, so its job table only refreshes when an explicit wait4
runs: `kill %1` landed the pgrp SIGTERM correctly (measured
`kill(-4, 15)`), yet `jobs` still printed `Running` until `wait %1`
reaped the zombie. The notification path is absent *by ruling*, not
by bug — the honest oracle pulls the fact.

- **`$? = 128+signo` is sharper evidence than the notification
  line.** `wait %1` returning `st=143` names signal 15 landing on
  the job — a notification string only says something happened.
- **EINTR names caught arrivals only.** nanosleep's first version
  cut on any pending unblocked bit — `fg`'s SIGCONT (a pending
  default fact) ended `sleep 30` after ~9 s and the whole
  stop/resume sequence collapsed downstream. A sleep ignores pending
  default-action facts; only `sig_caught` arrivals EINTR it — the
  same partition pause() doesn't need but nanosleep does.
