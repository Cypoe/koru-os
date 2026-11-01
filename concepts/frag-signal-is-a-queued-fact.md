---
type: belief
id: frag-signal-is-a-queued-fact
provenance: koru-os native session — signalfd/timerfd arming rung, 2026-11
ts: 2026-11-01
tags: [native, signals, signalfd, event-loop, contract, wayland]
---

**A signal on this arm is a queued fact, not an interruption.** There
is no asynchronous delivery path: `rt_sigaction` registers a handler
that can never fire (stored metadata, honestly answered), and
`rt_sigprocmask`'s block set is real recorded state consulted only by
the next `oldset` read — never by a dispatcher that doesn't exist.
What exists instead is the consumer shape every real event loop
already wants: `signalfd`/`signalfd4` projects the child's pending
queue as an fd whose mask selects which facts dequeue as
`signalfd_siginfo` bytes, readiness `pending ∩ mask` riding the same
`fdPollRev` path as every other channel.

Producers must be real kernel events, and there is exactly one so far:
child death queues `SIGCHLD {code: CLD_EXITED, pid, status}` on the
spawner (`spawned_by`, recorded at spawn/fork — the roster is flat, so
the link is custody, not hierarchy). A parent with no `.sfd`
projection simply carries the pending bit; creating the fd later still
dequeues it — pending is state, not a message to a listener.

Coalescing is the posix non-RT answer, stated: a second instance of a
pending signo merges (the bit stays, the payload refreshes), and an
unseen signo on a full queue still marks the bit — the read reports
the signo with a zeroed payload. The fact survives; the detail may
not. Held consequence — `wait()` and the signalfd are two reads of the
same truth, not two truths: a `SIGCHLD` read never reaps, and wait
never consumes the queue.

Rejected alternative — wiring `SIGCHLD` as an *interrupt*: the moment
delivery could suspend running code, every pending fact would need a
re-entry contract (frame snapshot, mask save, restart policy) the arm
cannot currently honor. signalfd's whole point on Linux was never
needing that machinery; here it is the entire mechanism.
