---
type: belief
id: frag-loader-loads-through-the-spawned-view
provenance: koru-os native session — PT_INTERP rung, 2026-10
ts: 2026-10-25
tags: [native, elf, dynamic-linking, fs, mmap, oracle]
---

A dynamic executable's interpreter is loaded **through the scoped fs
view, not around it**. PT_INTERP names a path; the kernel resolves it
with exactly the `ChildFsOps` the child itself would get — open →
read_at — and that is the whole mechanism: a second ET_DYN at
`INTERP_BASE`, `AT_BASE` in the auxv, done. No loader-private file
channel exists, and none should.

Three measured lessons the rung exposed:

- **The kernel streams; it never buffers an image.** `loadViaFs`
  reads ehdr+phdrs through a 4 KiB stack buffer and fills each
  PT_LOAD's mapped pages directly via `read_at`. A whole-file copy
  is what the 4 MiB bump heap couldn't afford — and the right answer
  is not a bigger heap, it's that buffering was never required.
  `free` being a no-op makes every malloc a lease; treat it that
  way.
- **Prot applies to the mapping, not the allocation.** musl's
  `map_library` reserves a span PROT_NONE, then MAP_FIXEDs each
  LOAD with its real prot — pages already mapped must pick up the
  new W bit or GOT writes fault RO. `setUserWritable` runs
  unconditionally with the final prot; never conditionally on
  "did we just map this". The x86 page model can't express
  PROT_NONE (no read-disable bit) — reads stay allowed, and that
  is honest: NXE isn't on, PROT_EXEC is advisory, the W-bit is the
  real axis.
- **fs size is not a constant in the read path.** The 16 MiB image
  crossed one block group and three things broke honestly:
  `inodeLoc` had to read the GDT (inos are global, group-scoped
  only inside a group), `create` had to allocate *per-group*
  bitmaps+counts (decrementing group 0 unconditionally underflowed),
  and sparse holes read as zeros, not errors. A provider that
  assumed "small rootfs" was wrong on contact with a real one.

Gate shape: a zig-built `hi.elf`+`liblibhi.so` crosses a non-self
DSO boundary; BusyBox v1.37.0 runs through musl ld.so; GNU
coreutils `uname` runs a 5-lib closure and answers `koru-os` —
the kernel's own name through `uname(63)`, never a Linux costume.
Refuses on the trail (getuid=102, prctl=157) are the loud axis —
a cap the bag can't express refusing by name is the spec working.
