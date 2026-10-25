---
type: belief
id: frag-fd-projects-a-typed-endpoint
provenance: koru-os native session — pipe-seam rung, 2026-10
ts: 2026-10-25
tags: [native, fd, pipe, spawn, wait-keys, zombie, lifecycle, contract]
---

A syscall fd is a **projection of a typed endpoint**, not a provider
handle by number. `Child.fds[]` carries an id per slot and `fdkinds[]`
carries what the slot projects: `conin`/`conout` (stdio are real
entries — closing fd0 detaches like any discharge), `fs` (a scoped-view
handle), `pipe_r`/`pipe_w` (ends of a kernel ring). read/write/close/
fstat dispatch on the kind; an fs write is EROFS by kind, not by flag
lookup, and a pipe fd gets an honest S_IFIFO fstat.

The pipe itself is a bounded kernel ring (2KiB) with refcounted ends —
the fifth wait kind `.pipe` + `wait_pipe` rides the same kernel-
continuation machine as conin/blk/exit: reader parks on empty while
writers live, writer parks on full while readers live, and the wake is
mark-only — the recheck loop is what sees bytes, space, EOS (last
writer gone → drain-then-0), or EPIPE (last reader gone → -32 on the
woken writer). Endpoint refs move on `pipe()` (mint), spawn-wiring
clone (bump), and close/exit (drop); the ring dies with both ends.

Wiring is **explicit per spawn**, never inherit-all: nr513 spawn_start
is nr512's detached twin — same `spawnBuild`, plus r8/r9 naming the
caller's fd entries to project into the child's fd0/fd1. **Fd-dup is a
per-kind endpoint operation, not a table copy** — fork made that ruling
unavoidable: pipes bump the ring's endpoint refs; an `.fs` clone calls
the provider's `dup` op (`ChildFsOps.dup`, ext2's OpenFile carries a
refcount) and `releaseFds` drops refs, never closes outright. The file
offset lives in the shared OpenFile — a child's read advances the
parent's cursor, which is POSIX fork semantics, not two opens. The
prior claim that "an fs clone SHARES the handle" was aspirational: it
shared the pointer but `releaseFds` closed unconditionally — a latent
double-close no fixture had wired an fs fd into until fork wired all of
them. Detached implies lifecycle: the
child is `.waitable`, its death leaves a `.zombie` holding
`exit_status`, and nr61 wait(pid,status) — pid is the roster-slot nid,
-1 waits any — claims it once; reap marks `.dead` so a reused slot can
never serve a claimed status twice. The status word is wait4-encoded
(code<<8) — musl's WIFEXITED/WEXITSTATUS decode it; writing the raw
code is a lie musl can't read. koru's verbs moved to nr512
(fused spawn+park+status in rax) and nr513 (spawn_start) when musl's
nr57 turned out to be REAL fork — low numbers are Linux's table, ours
live at 512+ (see frag-fork-is-eager-copy-at-the-syscall-edge). A
pipeline is two nr513s + closes + two nr61s, and the READER spawns
first so reader-parks-on-empty is deterministic evidence, not timing
luck.

Oracle lessons this rung paid for:

- `int` through musl `syscall()` varargs reaches r8/r9 with poisoned
  high bits (observed `0xaaaa0003`) — kernel-side EBADF looked like a
  wiring bug but the fd never arrived clean. Cast to `long` at the call.
- Writing an fd pair to user memory byte-by-byte and stopping at 2 of 4
  bytes leaves `0xaa` poison in the int — `writeInt` the whole slot.
- A gate run's `timeout` is part of the fixture's budget: three shell
  command rounds at key-injection cadence outgrow 15s, and the failure
  reads as "evidence missing" with the serial ending mid-reprompt.

Evidence: `pipegen.elf | catc.elf` typed through the new shifted kbd
table (`|` is shift+backslash — a real sendkey chord, no fixture dodge);
serial shows `PIPE-DATA-1234567890` echoed back out of `catc` through
its own conout, `CATC n=20` full drain, `pipe: w=52 r=51` both zombies
reaped, `rwaits=1` in the sched line — the reader's read parked on the
empty ring before the writer existed. Boot gate 31/31.
