---
name: klanker-child
iface: koruos/oracle.klanker
arms: [koru-native]
lane: oracle
needs: [py-cpython-child]
accept: klanker + agents-* deps run under the CPython child; REPL answers, bot-to-bot over unix socket
tier: qemu
status: open
evidence: —
peer: klanker (~/repos/klanker, MIT, Lolaplex)
provenance: project-owned codebase — no donor diligence needed
---

# klanker-child

klanker — the Lolaplex agent shell — running unmodified inside the
CPython child: `klanker` REPL answers a line, and two children hold
bot-to-bot traffic over a unix socket (the same-kernel shape that
needs no AF_INET at all).

## Acceptance

initramfs carries `/usr/lib/python3/*` site-packages: `klanker`,
`agents-harness`, `agents-relay`, `agents-memory`, `agents-traces`,
`agents-docs`, `agents-terminal`, `agents-calendar`. The child runs
`python3 -m klanker` (or the scripted entry), answers a scripted
prompt, and a second child exchanges a message over
`/run/bot.sock`. Serial evidence lines, status=0.

## Notes

- klanker is pure CPython ≥3.10; every dependency is a project-owned
  `agents-*` stdlib package — no wheels, no C extensions in the core
  path. `pyratatui` TUI is optional (pty/termios already landed).
- The honest blockers this slot will measure: `threading` use inside
  agents-harness (stub vs `clone-threads`), `subprocess`/execve,
  sqlite3 locking paths, `asyncio` on our epoll.
- 24/7 bot-to-bot on one kernel is the demo shape: two children, one
  unix socket, zero network — the compositor's own socketpair work
  already proved the channel.
