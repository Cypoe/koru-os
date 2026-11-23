---
type: belief
id: frag-the-inherited-frame-is-not-scratch-space
provenance: koru-os native session — glibc __clone3 thread spawn, 2026-11
ts: 2026-11-17
tags: [native, clone3, threads, glibc, syscall, contract]
---

**The trap frame a thread member inherits is the caller's register
state — never scratch space for argument translation.** clone() packs
its operands in registers (flags/stack/ptid/ctid/tls), so the natural
clone3 translation rewrites the frame's rdi/rsi/rdx/r10/r8 from the
struct and reuses the clone path. That rewrite is a lie the child
sees: glibc's `__clone3` wrapper deliberately stashes the thread
function in `%rdx` and its argument in `%r8` — registers the syscall
does not consume — precisely so the clone3 member inherits them
through the register copy. Translating `f.rdx = parent_tid` made the
child `call *%rdx` a `call *(&pd->tid)` — a #UD at a data pointer, and
a fault that looked like heap corruption rather than an ABI error.

The ruling the oracle forced: struct-form syscalls feed the dispatch
through *parameters*, never by mutating the inherited frame.
`childCloneFrom(c, f, flags, stack, ptid, ctid, tls)` takes the
resolved values by name; `childClone` unpacks registers, `childClone3`
unpacks the struct — the caller's frame survives intact for the member.

Held consequence — this generalizes: any syscall whose new context
inherits the caller's registers (clone family, vfork, rt_sigreturn
adjacent paths) treats the frame as *published state*. Validation and
translation happen on copies or parameters, not on the frame the
member will resume with. Linux's own rule, restated: clone3's struct
is read kernel-side; the user's registers pass through untouched.

Adjacent but distinct: `pidfd` in clone_args is flag-gated
(`CLONE_PIDFD` only) — glibc hands the field a scratch pointer
unconditionally and linux ignores it; a nonzero field without its
flag is not a refusal.
