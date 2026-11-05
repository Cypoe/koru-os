---
type: belief
id: frag-the-linux-twin-is-the-ldisc-oracle
provenance: koru-os native session — pty/termios rung, 2026-11
ts: 2026-11-01
tags: [native, pty, termios, oracle, differential, ldisc, abi]
---

**The cheapest line-discipline oracle is the same C file compiled
twice.** `koru/native/tests/ptytest.c` builds once with
`-DKORU_DOOR` (pair minted through nr521) and once without
(`posix_openpt`/`unlockpt`, real linux). Running the twin under WSL
before trusting the kernel-side reading caught four facts a
code-review reading of n_tty had already gotten wrong:

- **ioctl `cmd` is `unsigned int` on the wire.** musl passes
  request constants as `int` — `TIOCGPTN` (0x80045430) arrives
  sign-extended to 0xFFFFFFFF80045430 in `rsi`. Comparing the full
  u64 gives ENOTTY where linux answers; `sys_ioctl` truncates, and
  so must we. Any request ≥ 0x80000000 (the `_IOC_READ`-sized
  family) is invisible to a u64-exact dispatch.
- **Linux's signal flush discards *uncommitted* echo.** n_tty
  echoes into a pending ring a signal flush drops — typed input
  that arrived before the ^C never reaches the master ("^C" alone,
  2 bytes). Koru echoes eagerly into the out-ring, so "zz^C" is our
  lawful shape: the observable contract is glyph-at-end, not byte-
  equality. An eager-echo ldisc is not a bug; it is a different
  lawful realization the test must phrase around.
- **ECHOKE suppresses the ECHOK newline.** With the linux default
  lflag (0x8a3b), VKILL erases the line visually (BS SP BS per
  char) and emits *no* `^U` glyph and *no* newline — the newline is
  only the fallback when nothing was erased.
- **signalfd only claims blocked signals.** Unblocked, the ^C's
  real SIGINT fires its default disposition first — the twin died
  128+2 before the fd read anything. The mask is part of the API
  contract, not a courtesy; and on linux ISIG/TIOCSWINSZ need a
  controlling terminal at all, which the koru `owner` model does
  not require. Documented model difference, not a bug either way.

The method generalizes: wherever linux's syscall semantics are the
de-facto spec (termios, poll edge cases, wait flags), the oracle is
a `-D` flag and a WSL run — not a spec document you have to trust
your reading of. Where the twin and the kernel legitimately differ
(model differences like ctty/sessions, emulation edges like WSL's
looser EIO), the test prints evidence and the comment says which
side owns the variance.
