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
view. `scripts/fetch-pyroot.sh` rebuilds the ~21MB cpio on demand —
it is never committed.

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
- No AF_INET, pthread, or futex demand surfaced for this probe —
  `clone-threads`/`net-*` stay gated on a consumer that names them.

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
