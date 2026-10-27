---
type: belief
id: frag-poll-is-readiness-not-a-syscall
provenance: koru-os native session — unmodified libwayland-client rung, 2026-10
ts: 2026-10-27
tags: [native, poll, event-loop, fd, readiness, wayland, contract]
---

**Poll is a readiness projection over fd kinds, not a primitive and
not a socket feature.** Every typed endpoint already owned its own
blocked-wait arm (`.wait_pipe`, `.sock`, `.lback`, `.sconn`) — each
kind's release path already knows exactly when its endpoint becomes
readable or writable. `poll`/`ppoll` adds one multi-way evaluator over
those same criteria and parks on a single `.poll` WaitKind; the SAME
release sites that wake direct readers broadcast `wakeKind(.poll)` —
one broadcast per endpoint-mutation site, not a new wake taxonomy. The
deadline rides the existing LAPIC tick wake; ppoll's nanosecond mask
arm is a folded syscall number, not a second mechanism.

Held consequence: **a new fd kind implements readiness once — in its
own release path — and poll inherits it.** Poll never grew a
pipe-specific or socket-specific arm; the evaluator asks each fd's
kind what "ready" means (pipe ring bytes/space, socket ring + pending
fd queue + listener backlog, kbd ring). That is why unmodified
libwayland's real event loop ran on the first try once the evaluator
existed: `wl_display_dispatch`'s ppoll waits on socket readability are
exactly `.sock` readiness, already released by `sockWrite`'s
far-end wake.

Sister rulings the same rung proved: **dup is projection copying, not
number minting** — `fcntl F_DUPFD`/`F_DUPFD_CLOEXEC` and `dup`/`dup2`/
`dup3` share the endpoint and its refcount (a stub returning 0 would
hand the received pool fd back as stdin — silent corruption, worse
than a refusal); **`MSG_DONTWAIT` is a flag on the read, not a mode on
the endpoint** — EAGAIN is the evaluator's "not ready now" answer, the
same predicate poll uses. `clock_gettime` reads the calibrated
monotonic clock — libwayland times its dispatch loop with it.

Evidence: `wlreal.elf` — the vendored libwayland-client 1.26 sources
(connection/wayland-client/wayland-os/wayland-util + generated glue +
libffi.a demarshalling) linked UNMODIFIED — connected on the path
endpoint, demarshalled registry globals + shm formats through ffi
closures, drove its real ppoll loop, took the pool fd over SCM_RIGHTS,
and completed the session (`WLR frame done=42`, `WLR sync done=43`,
`WLSRV magic=deadbeef tag=00c0ffee px0=5a`, EOS, `WLRINIT srv=0
cli=0`), uniprocessor and under `-smp 4` with children claimed on
different APs. Boot gate `wlreal` row.
