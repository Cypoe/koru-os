---
type: belief
id: frag-checked-arithmetic-on-untrusted-fields
provenance: koru-os native session — loadElf phdr walk, 2026-11
ts: 2026-11-17
tags: [native, elf, hardening, refusals, contract]
---

**Checked arithmetic on file-controlled fields is a panic surface,
not a bounds check.** `loadElf`'s phdr validation read
`phoff + phnum * phentsz > b.len` — a corrupt image carrying
`e_phoff` near u64 max wraps the checked add and zig's safety trap
fires `ud2` in kernel space. The honest answer to a malformed payload
is `ELF REFUSE` — a kernel that panics on a bad binary converts a
userspace input error into a system crash, the worst possible
refusal.

The ruling: order guards so every add/sub on untrusted values is
provably non-wrapping *before* the operation. `phoff > b.len` first,
then `phtab > b.len - phoff` — subtraction after the bound holds,
never the sum before it. Same shape for `off + filesz`, `bias + vaddr`,
`va + memsz`, and the entry add: the file's u64 fields are hostile
input, and every comparison gets the difference form.

Held consequence — this is the refusal doctrine at the arithmetic
layer: refuse by name at the point the contract fails, in a form the
caller can observe, never as a trap in kernel bookkeeping. A panic is
a claim that the input was trusted; an ext2 inode is not trusted.
Same family as the USER_VA_END bump-mmap bounds: the kernel's own
arithmetic is part of the attack surface the contract speaks to.
