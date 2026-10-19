# M6: KMS scanout of a dumb buffer (DESIGN-0001 §0.4 "M6 acceptance")

**Result (M, TCG only, 2026-10-19 13:36 CEST): PASS 3/3**, all checks (k1)–(k6) and (x).
Regressions on the same kernel, 13:37–13:39 CEST: M3 3/3, M4 (a)–(d) 3/3, M5a 3/3
(`evidence/regress-*`).

## What runs
- **Kernel.** The M5a arm plus `lib/korukms` and the two patches in `patches/`, built from the
  pristine kraft sources by `build-image.sh` (`W=/workspace/m6kclean`; sha256 `82027a73…`,
  653,744 B).
- **Display device.** QEMU `-vga none -device bochs-display` (PCI 1234:1111, 16 MiB VRAM,
  EDID on). The native provider (`lib/korukms/bochs.c`) binds the `kms.*` rows; the DRM
  personality (`lib/korukms/drm_linux.c`) serves `/dev/dri/card0`.
- **Programs**, from the ext2 root under the M3 hush (`m6-init`), dynamic glibc 2.41:
  `kmsdumb` (`kmsdumb.c`, raw ioctls) and Debian `libdrm-tests` 2.4.124 `modetest`, unmodified,
  as `sleep 4 | modetest -M korukms -s Virtual-1:1024x768`.
- Not committed: busybox, glibc, libdrm, modetest, disk images, screendumps.

Reproduce: `apt-get download libdrm-tests libdrm2` and `dpkg-deb -x` both into a root,
`./build-image.sh`, then `./run-m6.sh <kernel> <static busybox> <libdrm root> <outdir>`.

## Measurements

| run | QEMU wall (incl. 3 s + 3 s + 4 s guest pauses) | (k2) A | (k3) B | (k4) SMPTE | refusal rows |
|---|---|---|---|---|---|
| 1 | 15.407 s | 0 / 786,432 px differ | 0 | 0 | 27 rows, 7 names, all classified |
| 2 | 11.276 s | 0 | 0 | 0 | same |
| 3 | 11.277 s | 0 | 0 | 0 | same |

The three screendumps have the same sha256 in every run (`evidence/run-*/screendumps.sha256`):
A `38ca8448…`, B `6f40923b…`, SMPTE `2617dc40…`.

## L1 twin (oracle, not a pass)
`run-l1.sh`: Debian `linux-image-6.12.113+deb13-amd64`, `bochs-drm` and its five module
dependencies, an initramfs with the same `kmsdumb` and `modetest`, `strace -f`, TCG
(2026-10-19 13:33 CEST, `evidence/l1/`).
- All three Linux screendumps are pixel-exact against the same references, **and
  byte-identical to the koru-os screendumps** (same three sha256).
- The ioctl histograms are in `evidence/l1/result.txt`; the full traces are
  `kmsdumb.strace` and `modetest.strace`. kmsdumb issues exactly the same DRM ioctls on both.
- Differences (Linux vs koru-os M6): Linux reports 15 modes (koru-os 4), two planes (primary
  + cursor; koru-os 1), properties on every object (modetest calls `GETPROPERTY` 16 times;
  koru-os reports none), accepts `DRM_CLIENT_CAP_ATOMIC` (koru-os refuses, k5), and serves
  legacy gamma (koru-os refuses `SETGAMMA` with `ENOSYS`, which modetest ignores).

## Found on the way
- Unikraft localizes every library symbol that is not in that library's `exportsyms.uk`, so
  a weak default in `posix-mmap` could not be overridden from the application until the
  hook was exported (first probe: `mmap` of the dumb buffer fell through to the file VMA and
  failed with `EOPNOTSUPP`, because vfscore cannot do writable shared file mappings).
- devfs was flat; libdrm opens only `/dev/dri/card<N>` (`drmOpenByName` → `drmOpenMinor`),
  so devfs got one level of subdirectory, `st_rdev` (226:0) and the vnode mode.
- The Unikraft 0.21 virtio-pci transport is legacy only. QEMU's virtio-gpu and virtio-input
  devices are virtio 1.0 devices, so neither is reachable without a modern transport
  (BLOCKERS B13).
