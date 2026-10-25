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

Wiring is **explicit per spawn**, never inherit-all: nr58 spawn_start
is nr57's detached twin — same `spawnBuild`, plus r8/r9 naming the
caller's fd entries to project into the child's fd0/fd1. The clone
bumps pipe refs; an fs clone SHARES the handle (dup semantics — same
offset, not an independent open). Detached implies lifecycle: the
child is `.waitable`, its death leaves a `.zombie` holding
`exit_status`, and nr61 wait(pid,status) — pid is the roster-slot nid,
-1 waits any — claims it once; reap marks `.dead` so a reused slot can
never serve a claimed status twice. nr57 stays fused (spawn+park+status
in rax) for the common case; a pipeline is two nr58s + closes + two
nr61s, and the READER spawns first so reader-parks-on-empty is
deterministic evidence, not timing luck.

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
