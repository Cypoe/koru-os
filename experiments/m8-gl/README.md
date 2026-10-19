# M8a: offscreen GL through Mesa llvmpipe (EGL surfaceless and EGL on GBM)

**Result: PASS 3/3 under TCG, 2026-10-19 14:15 CEST** (after the freeze commit `a136a3a`),
on the unchanged M7a kernel (`/workspace/m7kclean`, sha256 `68e7f446…`). QEMU wall 11.554 /
11.746 / 11.386 s (boot to poweroff, both gloff runs, 1 GiB guest, ~200 MiB of unmodified
Debian GL userland loaded from the ext2 root). Criteria: DESIGN-0001 §0.4 "M8a acceptance".
M8b (`kmscube`, the table's M8 criterion) is open.

## What runs
`gloff` renders two 256×256 frames into an FBO with GLES2 and reads them back, once on the
Mesa surfaceless platform and once on GBM over `/dev/dri/card0` (the M6 native KMS provider;
Mesa takes `kms_swrast`, the renderer is llvmpipe in both cases). Userland: glibc 2.41, glvnd
1.7.0, Mesa 25.0.7, LLVM 19.1.7, all unmodified Debian 13 binaries, assembled by `mkroot.sh`
(nothing of it is committed).

## Results (each run)
(g1)/(g3) `llvmpipe (LLVM 19.1.7, 128 bits)`, `OpenGL ES 3.2 Mesa 25.0.7`, FBO complete,
frame hashes `9c784fad9c82cce9` / `5be5b6b059035ef9` on both platforms. (g2) probe pixels as
derived from the geometry. (g4) 18 refusal rows, all classified (new: `memfd_create`, the
`sched_getaffinity` stub); Mesa messages only `MESA-LOADER: failed to retrieve device
information` (B15, no sysfs) and `kmsro: driver missing` (also on L1). (g5)/(x) clean.

## L1 twin (`run-l1.sh`, 2026-10-19 14:13 CEST)
Debian 6.12.113 + `bochs-drm`, same userland and `-cpu`: the same two hashes on both platforms
(the box host with AVX2, 256-bit llvmpipe, also gives them). `strace -f -c` summaries in
`evidence/l1/serial-programs.log`.
