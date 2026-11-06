# korukms: kms.* rows, a native bochs-display provider, and the Linux DRM personality (M6)

| file | role |
|---|---|
| `kms_rows.h` | The seam: the `kms.*` driver rows (DESIGN-0001 §0.6, Appendix C.4). `kms.modes`, `kms.vram` (provider data), `kms.scanout`, `kms.disable` (provider calls). The personality never touches registers; a provider never sees an ioctl. |
| `bochs.c` | Native koru-os provider for QEMU `bochs-display` (and QEMU std VGA, same PCI id 1234:1111 and BAR layout). PCI config access, BAR0 = VRAM, BAR2 = MMIO with the DISPI registers at +0x500 and EDID at +0x000. Modes: the EDID preferred mode plus 1024×768, 800×600, 640×480. Written from the QEMU device register layout; no Linux code. |
| `drm_linux.c` | Linux-ABI DRM personality on `/dev/dri/card0` (char 226:0): `VERSION`, `GET_UNIQUE`, `GET_CAP`, `SET_CLIENT_CAP` (universal planes), `SET/DROP_MASTER`, `MODE_GETRESOURCES/GETCRTC/SETCRTC/GETENCODER/GETCONNECTOR/GETPLANERESOURCES/GETPLANE/OBJ_GETPROPERTIES`, `MODE_CREATE_DUMB/MAP_DUMB/DESTROY_DUMB`, `GEM_CLOSE`, `MODE_ADDFB/ADDFB2/RMFB/DIRTYFB`. One CRTC (32), encoder (33), connector (34, `Virtual-1`), primary plane (31); XRGB8888 dumb buffers carved first-fit out of `kms.vram`. Everything else is refused loudly as `koru-os: REFUSED linux.ioctl.<name> (kms)` with the errno a Linux driver lacking the feature returns (atomic: `EOPNOTSUPP`; gamma: `ENOSYS`; others `EINVAL`/`ENOTTY`). It also implements `koruos_dev_mmap()`, so `mmap()` of a `MAP_DUMB` offset maps the buffer's VRAM pages directly. |
| `drm_uapi.h` | The Linux DRM uAPI subset (struct layouts, ioctl numbers), written out so the unikernel build does not need host kernel headers. |
| `tests/abi_check.c` | Host check that `drm_uapi.h` equals `/usr/include/drm` (sizes, `_IOC_SIZE`, ioctl numbers). `cc -I.. -I/usr/include/drm tests/abi_check.c && ./a.out` → `ABI CHECK PASS` (2026-10-19). |

Unikraft 0.21 needs two patches for this (`experiments/m6-kms/patches/`):
- `devfs-subdir-rdev`: devfs names may carry one `/` (so `/dev/dri/card0` exists; libdrm opens only that path), readdir lists one level, and `stat()` reports `st_rdev` and the mode.
- `posix-mmap-device-hook`: a weak `koruos_dev_mmap()` lets a device claim an `mmap()` of its file and map physical memory (a DMA-type VMA), instead of vfscore's copy-on-fault file VMA, which cannot do writable shared mappings.

**Why native and not DS3 (decision, DESIGN-0001 §0.4 "M6 decision").** The provider is koru-os code behind the same `kms.*` rows a GPU driver silo will export. DS3 (LKL `virtio_gpu` in a silo) is not dropped; it re-binds `kms_rows.h` to a silo instead of `bochs.c`, and the personality and tests stay as they are.

Not done: atomic KMS and properties (M9 needs them for aquamarine), page-flip events and vblank (`read()` on the fd), PRIME, cursor planes, more than one client, a writable `dumb` lifetime model (a destroyed buffer still backs a live fb, as on Linux, but without refcounts), virgl/3D.

M2 upstream-lane join measured (evidence/m2-join/): unmodified
Debian modetest opens `/dev/dri/card0` served by `virtio_gpu.c`,
enumerates `Virtual-1` 640x480, and a real modeset paints — host
screendump shows the color band. The provider does manual virtio
over raw PCI because the Unikraft 0.21 virtio-pci driver is
legacy-only (virtio-gpu is a virtio 1.0 device).

## virtio-gpu provider (virtio_gpu.c)

Binds `kms.*` for QEMU `virtio-gpu-pci` (virtio 1.0, 2D scanout — no virgl).
`kms.vram` is a page-allocated guest pool attached as a host 2D resource:
`scanout` is CREATE_2D (per pitch) + SET_SCANOUT + TRANSFER_TO_HOST_2D +
FLUSH; `disable` is SET_SCANOUT with no resource. Two QEMU model lessons
are baked in: `dma_map` refuses phys ranges spanning the ISA hole
(0xa0000–0xfffff), so the pool is allocated above 1 MiB; and ATTACH_BACKING
entries are emitted per contiguous *physical* run because a VA-contiguous
pool is not phys-contiguous under paging — one entry for the whole pool
truncates the display at the first phys discontinuity.
