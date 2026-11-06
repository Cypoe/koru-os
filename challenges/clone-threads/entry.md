---
name: clone-threads
iface: koruos/proc.thread
arms: [koru-native]
lane: native-zig
needs: []
accept: clone(CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND) mints a second runner on one domain; futex wakes a parked peer
tier: qemu
status: open
evidence: —
peer: —
provenance: —
---

# clone-threads

Real threads inside one child domain: `clone` with the
`CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_SIGHAND` shape mints a second
CPU context sharing address space, fd table, and signal dispositions
— the musl `pthread_create` path end-to-end, plus `futex` for the
park/wake half of the GIL.

## Acceptance

A musl child `pthread_create`s a worker: both write distinct lines,
the parent's `futex` waits and the worker's wake releases it,
`gettid` returns distinct ids in one pid, `pthread_join` reaps.
status=0.

## Notes

- Only file if `py-cpython-child` measures real `threading` demand —
  a stub-pthread shim may carry klanker first (main-thread CPython
  runs fine; asyncio needs no threads).
- Big sub-pieces: shared-page-table domains (cloneUserSpace already
  shares CR3 family), per-context kernel stacks, `futex` wait/wake
  as a wait kind, `exit` vs `exit_group` semantics (thread vs
  process death), signal routing per-tid.
