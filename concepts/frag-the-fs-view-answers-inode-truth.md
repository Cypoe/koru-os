---
type: belief
id: frag-the-fs-view-answers-inode-truth
provenance: koru-os native session — Debian foot 1.28 / fontconfig 2.15, 2026-11
ts: 2026-11-16
tags: [native, fs, stat, readdir, glibc, oracle, contract]
---

**A fs view may refuse, but it may not answer constants — real libcs
validate stat against the inode.** Two near-identical lies passed every
musl consumer and silently broke glibc's fontconfig:

- `cfStat` answered `st_mode = 0o100644` for *every* handle, including
  directories. musl `opendir` never looks; glibc `opendir` does
  `fstat` + `S_ISDIR` → `ENOTDIR` → fontconfig skipped every font dir
  with no syscall ever failing loudly.
- `cfDent` answered `d_type = DT_UNKNOWN` when the ext2 dirent lacked
  `file_type`. Legal by POSIX — but fontconfig skips subdirs it can't
  type, so `truetype/` was never descended.

The ruling: **stat and readdir answers are derived from the inode, not
from the verb's convenience.** Mode comes from the inode's mode field;
`d_type` when absent on disk is derived from the same field, not zeroed.
A refusal (`ENOSYS`) is debuggable — a plausible constant is invisible
in every refusal grep and only surfaces as "the real client does
nothing". The oracle isn't "does it fail" — it's "does a caller that
believes the answer behave correctly".

Held consequence — when a real binary stalls with zero refusals, the
next suspect is a *satisfied* answer that was too convenient, not a
missing syscall.
