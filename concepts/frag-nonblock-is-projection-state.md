---
type: belief
id: frag-nonblock-is-projection-state
provenance: koru-os native session — py-cpython-child second pass, 2026-11
ts: 2026-11-10
tags: [native, fd, flags, asyncio, o_nonblock]
---

**Status flags a libc can observe are projection state — "our handles
carry no flag state" was wrong the moment a consumer asked for it.**
The earlier fcntl comment recorded the old belief; CPython's asyncio
retracted it: `socket.setblocking` speaks `ioctl FIONBIO`, the
selector loop then reads `EAGAIN` instead of parking, and
`F_GETFL`/`dup`/`fork` must all see the same bit.

- **The bit lives on the projection, not the object.** `fdnb` sits
  beside `fdverbs` for the same reason verbs do: a dup'd fd shares the
  open-file description's flags on linux, and our projection IS that
  description. SCM_RIGHTS arrivals and fork copies inherit it —
  `cloneFd` copies it like `fdverbs`.
- **Two doors, one bit.** `F_SETFL` (fcntl) and `FIONBIO` (ioctl)
  write the same flag; `F_GETFL` reports it. `SOCK_NONBLOCK` in the
  type word mints ends already flagged — silently stripping flag bits
  was a lie the measurement caught.
- **EAGAIN is the refusal shape.** The channel functions already took
  an `nb` arm for `MSG_DONTWAIT`; the fd flag ORs into the same arm —
  one mechanism, two callers. Blocking remains the default: only fds
  whose projections carry the bit answer EAGAIN.
- **Measured chain:** epoll loop → self-pipe socketpair →
  FIONBIO → nonblock sendto/recvfrom → timed epoll_wait.
  `PY asyncio 99 loop-bytes` is the evidence row.
