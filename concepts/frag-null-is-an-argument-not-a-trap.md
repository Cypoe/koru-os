---
type: belief
id: frag-null-is-an-argument-not-a-trap
provenance: koru-os native session — writev NULL-iov crash, 2026-10
ts: 2026-10-25
tags: [native, syscall, userspace, oracle, efault]
---

User pointers cross the seam as **integers**; the kernel decides their
meaning. ReleaseSafe lowers `@ptrFromInt` with a null check whose landing
pad is a shared `ud2` — and real libcs legally hand NULL to syscalls:
musl's `__stdio_write` appends a trailing `{NULL, 0}` iovec, and
`write(fd, NULL, 0)` is a valid no-op. The oracle's ruling: validity is a
function of *length and mapping*, never of non-nullness — `len==0` means
the pointer is not inspected at all, `len>0 && NULL` is `-EFAULT`, and a
user-supplied value must never be able to reach a compiler trap.

The crash class this names — **a compiler guardrail meeting legal user
data** — looked like stack corruption for hours: mid-instruction rip,
regs half-user on a kernel stack, no trap-marker print. It was none of
that; it was `@ptrFromInt(iov[1].base)` executing before the `len` check
rejected the iov. The whole `ud2` pad family is one mechanism: wherever a
user integer is materialized as a pointer, the semantic check comes
first. `write`, `writev`, `getrandom`, and the conin drain/wake paths now
all order it that way — `userEntry` present-bit before `userPhys`, never
the reverse.
