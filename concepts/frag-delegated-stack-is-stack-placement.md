---
type: belief
id: frag-delegated-stack-is-stack-placement
provenance: koru-os native session — net-uart-relay AF_INET rung, 2026-11
ts: 2026-11-16
tags: [native, net, providers, delegation, contract, naming]
---

**A delegated stack is a stack *placement*, not a stack *absence* —
the kernel still owns every millimetre of the socket contract.**
The AF_INET rung does not implement TCP: `socket(AF_INET,
SOCK_STREAM)` mints an ordinary `SockPair` whose peer end is owned by
a kernel bridge sentinel, `connect()` frames `CONNECT{ip,port}` onto
COM2 and parks until the host relay answers `COK`/`CERR`, and
`netrelay.py` on the host maps each session id to one real TCP
connection. The guest-side surface is entirely real: blocking connect
with `-115`/`SO_ERROR` for the nonblocking shape, `ECONNREFUSED`
through the CERR path, `poll` readiness off the pair ring, peer EOF
as ring-drain-then-zero, `close` as a `CLOSE` frame.

The honest line runs through the contract, not the wire format:
slirp already delegates TCP to the host *under* a real NIC — the
boundary just sits at L2 frames. The relay moves it to L4 socket ops.
What would make it a lie is pretending otherwise; what makes it a
provider is that the naming never lets you forget: the mechanism is
`net-uart-relay`, the rests_on says "the TCP stack placement is
host-side", and the gate row cannot pass without the host half
running.

Two corollaries the rung proved:

- **The pair model absorbs a remote peer for free.** Every existing
  arm — read/write/send/recv/poll/close/EPIPE — worked unmodified
  because a net socket *is* a pair whose sibling lives in the kernel.
  The only new surface was the handshake (`cst` states, `cerr`) and
  the frame drain.
- **Delegation does not waive refusal semantics.** `SOCK_DGRAM` still
  answers `-97`, unix-domain `getpeername` semantics don't leak into
  the inet answer, and options the placement can't honour refuse by
  name. A delegated provider narrows *where* the work happens, never
  *what* the contract promises.
