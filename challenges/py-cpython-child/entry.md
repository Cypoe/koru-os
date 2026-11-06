---
name: py-cpython-child
iface: koruos/oracle.cpython
arms: [koru-native]
lane: oracle
needs: [sessions-jobctl]
accept: alpine/musl python3 ELF runs as a child; print + asyncio.selectors + sqlite3 smoke
tier: qemu
status: open
evidence: —
peer: —
provenance: CPython is PSF-2.0; alpine/musl build is a shipping product
---

# py-cpython-child

An unmodified CPython interpreter — the alpine/musl `python3` ELF plus
its `.so` closure — running as a real child on the native kernel.
Every missing nr surfaces as a named refusal; the rung lands when
`python3 -c` prints, `selectors` arms an event loop, and `sqlite3`
persists through the scoped fs view.

## Acceptance

cpio carries `bin/python3` + lib closure + a `smoke.py`; boot fixture
execs it under a bag and the child's own output is the evidence:
`PY OK`, `PY LOOP`, `PY SQLITE`, status=0.

## Notes

- Already in hand: mmap-file/anonymous (busybox 1.37), PT_INTERP +
  dlopen closure (dynamic-gnu row), epoll/timerfd/eventfd/signalfd
  (asyncio's selector stack), unix sockets + SCM_RIGHTS, pty/termios/
  sessions/job-control.
- Known gaps to measure, not guess: `pthread` (stub shim vs real
  `clone-threads` — measure what CPython actually calls at startup),
  `execve` (nr59 arm — spawn is fused today), `setjmp`/`ucontext`
  edges, `socket(AF_INET)` (no net stack — unix sockets first).
- This is the substrate `klanker-child` rides; it is also the
  runtime an `arm-python-emit` dialect would target.
