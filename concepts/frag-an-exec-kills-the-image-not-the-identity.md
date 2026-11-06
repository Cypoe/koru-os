---
type: belief
id: frag-an-exec-kills-the-image-not-the-identity
provenance: koru-os native session — exec-verb rung, 2026-11
ts: 2026-11-10
tags: [native, exec, identity, lifetime, ordering]
---

**execve replaces the image; the identity is what the syscall owes
a contract to.** The rung's whole correctness story was ordering,
not loading — the loader already existed:

- **Marshal before teardown.** argv/envp are marshaled into kernel
  blobs while the OLD user pages still hold them — the strings die
  with the address space, so anything needed later must already be
  out. A sanity read of the ELF header happens before the unmap:
  ENOENT/ENOEXEC refuse with the image still alive (linux's
  pre-point-of-no-return shape); post-teardown failure is death —
  `childDie`, which is also linux's honest answer.
- **What survives is a specific list, and the list is the contract.**
  pid, slot, session, pgrp, bag, grants, fd projection. What dies is
  equally specific: pages, break, mmap cursor, pending signal facts,
  caught dispositions. The test passes stage-1's identity THROUGH
  argv and stage-2 checks survival as data — because "the pid is the
  same" is a fact to measure, not a name to assume.
- **The live frame IS the return path.** exec never returns to the
  old image: the syscall's own rcx/ursp get repointed, and the sysret
  epilogue lands in the new entry. noreturn-shaped code paths that
  "return 0" are honest about never reaching it.
