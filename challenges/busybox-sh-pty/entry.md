---
name: busybox-sh-pty
iface: koruos/oracle.shell
arms: [koru-native]
lane: oracle
needs: [sessions-jobctl]
accept: unmodified busybox sh drives fg/bg/&/^Z through a pty
tier: qemu
status: open
evidence: —
peer: —
provenance: busybox 1.37 already runs (dynamic row) — oracle not product
---

# busybox-sh-pty

The end-to-end terminal oracle: real `busybox sh` (already runs on the
fs view) attached to a pty slave, exercising interactive + job control
semantics — `&`, `fg`, `bg`, `^Z`, `^C` — through the whole
pty/termios/sessions chain. Oracle, not product — it proves the stack,
it isn't the shell we ship.

## Acceptance

Scripted run: sh on the slave, master injects `sleep 5 &`, `fg`, `^Z`,
`bg`, `kill %1`, `^C` — the child's outputs and the queued signal
facts all land. If job control works the whole terminal chain is
proven in one run.

## Notes

- Needs sessions-jobctl first — sh's job control is the acceptance.
- The gate shape is a master-side expect script in the fixture, not a
  human at a keyboard.
