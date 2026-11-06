---
name: py-cpython-child
iface: koruos/oracle.cpython
arms: [koru-native]
lane: oracle
needs: [sessions-jobctl, exec-verb]
accept: alpine/musl python3 ELF + full .so closure runs as a child via execve; print + fs read/write-refusal + fork/waitpid + pipe
tier: qemu
status: landed
evidence: V
peer: —
provenance: CPython is PSF-2.0; alpine/musl build is a shipping product (v3.20 main/x86_64)
---

# py-cpython-child

An unmodified CPython interpreter — alpine v3.20 `python3` 3.12.13
(PIE, musl) + its 17-apk dependency closure — running as a real child
on the native kernel. `/bin/pyrun` (musl stub) execve()s
`/usr/bin/python3 -S /main.py` through the exec-verb arm; PT_INTERP
(ld-musl) + the 8-NEEDED lib closure resolve through the initramfs
view. `scripts/fetch-pyroot.sh` rebuilds the ~24MB cpio on demand —
it is never committed. (26MB crossed GRUB's module-placement
threshold — the kernel died before serial init; the trimmed set
stays under it.)

## Acceptance — MET (QEMU serial)

`boot_py` → `pyroot.cpio` module, bag = named interpreter classes.
Serial: `PY hello 3.12.13`, `PY pid 1`, `PY argv /main.py`,
`PY read 1114 bytes`, `PY write refused errno 30` (EROFS on the
read-only view — asserted), `PY fork True status 7` (real fork +
waitpid + exit code), `PY pipe pipe-bytes`, `PY COMPLETE`, status=0.

## Measured gaps (all loud, all survived)

- `nr=89 readlink` ENOSYS — getpath/zipimport coped.
- `nr=19 readv` ENOSYS — bit granted, no arm; python continued.
- `nr=293 pipe2` ENOSYS — musl fell back to pipe(22).
- `nr=25 mremap` + `nr=324 membarrier` REFUSE — GC/arena init paths
  probe and degrade gracefully; not demanded hard.
- `nr=58 vfork` REFUSE (bit ungranted) — subprocess fell back to
  clone(56)'s fork shape, which is armed.
- No AF_INET demand surfaced — `net-*` stays gated on a consumer.

## Second pass — stdlib surface (extended probe)

With `threading`/`subprocess`/`asyncio`/`selectors`/`socket` and the
import chain (`ast`/`dis`/`opcode`/`inspect`/`importlib`/`contextvars`/
`typing`/`signal`/`string`/`re`/`logging`) in the payload:

- **`subprocess.run` GREEN** — pipe2→pipe fallback, fork clone,
  execve, waitpid: `PY subprocess 0 sub-ok`.
- **`asyncio` GREEN** — `PY asyncio 99 loop-bytes`: the Unix selector
  loop built (epoll_create, self-pipe socketpair), `call_soon` ran, a
  timed `epoll_wait` slept, and `loop.sock_sendall`/`sock_recv` moved
  real bytes through a nonblocking socketpair.
- **`threading` REFUSED, measured** — musl wants clone flags
  `0x7d0f00` (CLONE_VM|FILES|SIGHAND|THREAD|SETTLS|DETACHED); the
  fork-only clone arm refuses loudly → `RuntimeError: can't start new
  thread`. `clone-threads` is now proven demand, filed.

## Second-pass kernel changes

- `childSeek` dispatched every fd≥3 to `ops.seek` — `lseek` on a pipe
  passed a kernel handle as `*OpenFile` → provider-side `ud2`. Now
  `.fs`-only; all other kinds answer ESPIPE, linux's own word.
- `clock_getres`(229)+`clock_nanosleep`(230) folds →62, and the getres
  arm (ns-tick resolution; asyncio's `get_clock_info`).
- `getsockname`(51)/`getpeername`(52) folds →22 + arms — AF_UNIX
  answers (listener stores its bound `sun_path` at bind).
- `sendto`(44)/`recvfrom`(45) folds →22 + arms — stream verbs on
  connected ends (peer name ignored, MSG_DONTWAIT honored).
- **O_NONBLOCK is real fd state now**: `Child.fdnb` rides the
  projection (dup/fork inherit it), `F_SETFL`/`F_GETFL` honor it,
  `FIONBIO` is fd-wide (CPython `setblocking` rides it), socketpair/
  socket `SOCK_NONBLOCK` sets it, pipe+sock read/write dispatch ORs it
  into the nb arm — EAGAIN instead of parking.

## Kernel changes this rung forced

- `canonNr` interpreter-surface folds: uname/rlimit/rusage/sysinfo/
  id-family/rseq/close_range→62, waitid→61, clone3→57, cwd/chdir/
  link/readlink/chmod/chown/umask/mknod/statfs/*at/statx/openat2→2,
  pselect6+futex→22 — an unmapped nr≥64 is ungrantable by design.
- `getcwd`(79) arm — the view root IS the child's cwd, returns "/".
- `getdents64`(217) arm + `ChildFsOps.dent` — dir listing over the
  view; initramfs + ext2 implement it (read-only dir open, EISDIR on
  read, `.`/`..` synthesized for ramfs).
- `USER_STACK_PAGES` 16→256: CPython init overflowed the 64KiB stack
  (fault at va 0x7fdefcc8, one page below the window). No demand-grow
  exists — 1MiB fixed window per child.
