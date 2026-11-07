---
name: busybox-sh-pty
iface: koruos/oracle.shell
arms: [koru-native]
lane: oracle
needs: [sessions-jobctl]
accept: unmodified busybox sh drives fg/bg/&/^Z through a pty
tier: qemu
status: landed
evidence: check-boot busybox-sh-pty row — SHP COMPLETE fails=0
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

Scripted run: `ptysh` owns the session (setsid + openpty + TIOCSCTTY),
execs unmodified alpine busybox `ash` (dynamic apk + ld-musl closure)
onto the slave, and plays the master: `sleep 30 &`, `jobs`, `fg`, `^Z`,
`bg`, `kill %1`, `wait %1` ($? = 128+15 names the TERM), `^C` against a
foreground job, clean `exit`, master-side EIO after the slave dies.
`SHP COMPLETE fails=0` is the gate's green.

## Notes

- Needed nanosleep(35) landed — `sleep` is the job on trial.
- The master must ANSWER ash's ESC[6n cursor query (a real terminal
  does) or readline eats typed commands as the "reply".
- Stored-metadata ruling consequence: ash's SIGCHLD handler never
  fires, so async job-state refresh is impossible — the oracle asserts
  the death fact through `wait %1` + `$?=143`, not a notification line.
- The gate shape is a master-side expect script in the fixture, not a
  human at a keyboard.
