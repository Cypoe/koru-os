---
name: glibc-shim
iface: koruos/abi.libc
arms: [koru-native]
lane: koru-lift
needs: []
accept: deferred — lands the day a real app needs glibc extensions musl lacks
tier: qemu
status: waived
evidence: —
peer: —
provenance: —
---

# glibc-shim

WAIVED for now — deliberately unstarted. The shim-over-NIDs idea pays
for itself the day a real app assumes glibc extensions musl lacks
(libc_malloc hooks, RTLD_*, NSS, __libc_* internals). Banking on
musl's correctness is as wrong as banking on glibc's split — the
contract is ELF + POSIX-shaped syscalls + our own shim layer; libc
is packaging.

## Acceptance

Deferred by design. Activates when a concrete app (candidates: tmux
variants, a real browser, JVM-class runtimes) fails on musl in a way
that is genuinely a libc-shape gap and not a syscall gap.

## Notes

- Distinguish syscall gaps (our problem) from libc-internal gaps
  (shim's problem) — most "glibc needed" reports are actually the
  former in disguise.
- CPython does NOT reopen this: python:alpine proves CPython on musl
  is a shipping product, and klanker's agents-* tree is pure stdlib.
  The measured gap names itself `py-cpython-child` — revisit only if
  a glibc-only C extension (manylinux wheel without a musllinux
  build) ever enters the dependency graph.
