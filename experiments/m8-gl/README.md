# M8: GL through Mesa llvmpipe (M8a offscreen, M8b kmscube on KMS)

**Result: PASS 3/3 under TCG, 2026-10-19 14:15 CEST** (after the freeze commit `a136a3a`),
on the unchanged M7a kernel (`/workspace/m7kclean`, sha256 `68e7f446…`). QEMU wall 11.554 /
11.746 / 11.386 s (boot to poweroff, both gloff runs, 1 GiB guest, ~200 MiB of unmodified
Debian GL userland loaded from the ext2 root). Criteria: DESIGN-0001 §0.4 "M8a acceptance".
M8b (`kmscube`, the table's M8 criterion) passed 3/3 later, see below.

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

# M8b: unmodified kmscube on /dev/dri/card0

**Result: PASS 3/3 under TCG, 2026-10-19 14:24–14:26 CEST** (after the freeze commit
`2508cfa`), kernel `/workspace/m8kclean` (clean build, sha256 `29d2de82…`, 666,288 B; the M7a
arm plus legacy page flip, flip-complete events, `read()` and poll on card0 in
`lib/korukms/drm_linux.c`). QEMU wall 26.476 / 26.279 / 26.343 s (includes the 25 s stdin
pipe). Criteria: DESIGN-0001 §0.4 "M8b acceptance".

- (c1) EGL 1.5 Mesa, llvmpipe (LLVM 19.1.7, 128 bits), 149 frames in 10.6 / 11.6 / 11.3 s
  (14.1 / 12.8 / 13.2 fps), exit 0, 150 page flips.
- (c2) screendumps 1 s apart, 1280×800: about 200,000 non-grey pixels (the cube, ~20 %), at
  most 1 black pixel, about 206,500 pixels differ between the two. sha256 in
  `evidence/m8b-run-*/screendumps.sha256` (the images are not committed).
- (c3) 20 refusal rows, all classified; the only new one is `ADDFB2` with modifiers, which
  L1 `bochs-drm` refuses the same way. (c4) Mesa messages as in M8a. (x) clean.

L1 twin (`run-l1-m8b.sh`, 14:24 CEST): same mode, same `Modifiers failed!`, 149 frames at about
20 fps (vblank-paced flips), (c2) holds on its screendumps; 150 `pselect6`, 327 `ioctl`.
The koru-only lines (flip count, init status) do not exist there
(`evidence/m8b-l1/check-on-l1.txt`).

Regressions on the M8b kernel, 14:26–14:31 CEST: M3, M4 (a)–(d), M5a, M6, M7a and M8a each
3/3 (`evidence/m8b-regress-*`).

Inputs (not committed): `kmscube`, `libgstreamer-plugins-base1.0-0`, `liborc` via
`apt-get download`; gstreamer core, glib and libpng from the box.
