---
type: belief
id: frag-the-pty-oracle-must-answer-the-terminal
provenance: koru-os native session — busybox-sh-pty rung, 2026-11
ts: 2026-11-07
tags: [native, pty, termios, busybox, oracle, correctness]
---

**A pty oracle is a terminal peer, not a byte sink — a master that
never answers the terminal's protocol measures readline starvation,
not the stack.** Busybox ash's line editor emits `ESC[6n` after every
prompt and reads the cursor-position reply *from the same input
queue*; bytes that arrive while it waits are consumed as the "reply"
and discarded. Symptom shape: commands echoed but never executed,
eight-second silences, job notifications that never print — all
looking exactly like a broken ldisc while the pty was fine.

- **The driver answers.** `ptysh`'s read loop scans every chunk for
  `ESC[6n` and writes `ESC[row;colR` back — the same answer a real
  terminal gives. One protocol reply eliminated three phantom
  failures without touching the kernel.
- **Expect only grammar the oracle actually speaks.** Busybox prints
  no `[1] pid` at `cmd &` launch (only `bg` echoes `[1]+ ...`), and
  `kill %1` reports nothing — asserting guessed dash/bash grammar
  made two more phantom failures. The job table (`jobs`) and the
  wait status word are the facts; the prompt's return is the ack.
