---
name: koru-repl
iface: koruos/repl
arms: [koru-native]
lane: oracle
needs: [exec-verb]
accept: the c99-compiled interpreter bootstrap runs as a musl child and evaluates a line read from its conin
tier: qemu
status: open
evidence: —
peer: upstream/koru — the compiler/interpreter bootstrap is pure c99
provenance: koru toolchain (peer project)
---

# koru-repl

The Koru system interpreter as a first-class citizen of its own OS:
the toolchain's c99 bootstrap compiles to a musl ELF, runs as a
child, and evaluates a koru line typed on conin — the REPL the
platform was promised, booted on its own kernel.

## Acceptance

cpio carries the interpreter ELF + std modules; the child reads
`std/io:print.ln("hi")` (or the current bootstrap dialect) from
conin via sendkey, and the evaluated output lands on serial.
status=0.

## Notes

- The bootstrap being pure c99 is the cheat code: no zig required
  at runtime, just a musl compile of what already exists.
- Gap surface to measure: dynamic loading for `import`, file views
  for std modules, argv plumbing for script files.
- This is the Kopium precursor: a koru program that *is* the system
  interface — evaluating against the bridge/roster views
  (proc-roster-view, resource bridges) rather than a foreign shell.
