# M3 acceptance: busybox from the ext2 root (Unikraft 0.21.0, QEMU TCG)

Status: **PASS 3/3 (M, TCG, 2026-10-18, runs 20:25–20:27 CEST).**
`run-acceptance.sh` drives one disk image through two unikernels.

1. **Host.** `mke2fs -t ext2 -b 1024 -I 128 -N 512 -O none -d root` builds an 8 MiB image
   (one group). It holds static-PIE NOMMU busybox 1.37.0 (built by
   `experiments/m3-busybox/build-busybox.sh`), 400 applet symlinks, `/tmp` and `/dev`.
2. **M2 guest** (`koru/ext2` Koru lift). It allocates an inode and 10 blocks and writes
   `/dod1`, 10,000 B of the DoD pattern.
3. **Host check.** `e2fsck -fn` exits 0 ("416/512 files, 2406/8192 blocks"), and
   `debugfs cat /dod1` equals the pattern (sha256 `8b2e9313…67ce`).
4. **M3 guest.** app-elfloader with `koruext2fs` mounted by vfscore at `/` (read-only)
   and ramfs at `/tmp`. The init process is `/bin/busybox sh`, loaded from the ext2
   image. The scripted serial session runs:
   - `ls /` → `bin dev dod1 lost+found tmp`;
   - `cat /dod1` → the pattern lines;
   - `sha256sum /dod1` → equals the host pattern sha256;
   - `wc -c /dod1` → 10000;
   - `ls -l`;
   - `echo hello | tr a-z A-Z` → HELLO;
   - `exit 3` → the console shows `koru-os: init exited with status 3` (from
     `app/exitstatus.c`, see below).
5. **Disk unchanged.** The image is byte-identical across the M3 boot, and `e2fsck -fn`
   is still clean.

## Measurements (evidence/)

- `run-1..3/result.txt`: all checks PASS in each run.
  - M2 guest wall time 0.253–0.281 s.
  - M3 session wall time 22.01 s. That is almost entirely the scripted pauses
    (7 commands × 2 s + 4 s + 4 s).
- `refusal-and-timing.txt`:
  - Non-interactive `sh -c 'ls / >/dev/null; cat /dod1 >/dev/null; exit 3'`:
    boot to exit status 3 in 0.391–0.415 s wall.
  - Block traffic for that run: 14,752 blocks in 461 requests, 39,581 cache hits.
    busybox is loaded once per exec.
  - An ext4 image as root is refused at mount ("not a supported ext2 (95)"), the boot
    stops, and the image sha256 is unchanged.
  - `cat /bin/busybox > /dev/null` (2.36 MB) takes 0.364 s, but
    `cat /bin/busybox | wc -c` takes 21.8 s. The filesystem is not the bottleneck; the
    Unikraft 0.21 pipe is (observation O1 in BLOCKERS.md).
- Image: 624,880 B (no initrd). `libext2core.a` is 97,848 B.

## Pieces

- `app/`: Kraftfile, application `Makefile.uk`/`Config.uk`, `exitstatus.c`.
  - The Kraftfile is the `m3-busybox` one with the embedded initrd removed. It adds a
    custom fstab: CI0 `koruext2` at `/`, CI1 `ramfs` at `/tmp`.
  - `exitstatus.c` is a SYS-class term hook. Unikraft 0.21 computes the init exit status
    but prints it only at debug level, and QEMU's isa-debug-exit carries only
    crash/no-crash. The hook prints the status, so `exit 3` is observable at the
    unikernel boundary, not just inside a parent shell.
- `build-image.sh`: builds `lib/koruext2fs`, reuses the Unikraft, elfloader and libelf
  sources fetched for `m3-busybox`, and applies the three patches idempotently.
- Patches (`experiments/m3-busybox/patches/`):
  - `unikraft-0.21-posix-process-vfork-fsbase.patch`: B6, the vfork child's userland
    FSBASE.
  - `app-elfloader-empty-arg.patch`: B6, empty argv strings.
  - `unikraft-0.21-virtio-ring-destroy-vmem.patch`: new. With `LIBUKVMEM`,
    `virtqueue_destroy()` called `uk_free()` on a ring that had been mapped with
    `uk_vma_map_dma()`. That faulted at unmount, the first time anything unconfigured a
    virtio-blk queue. It is a backport of the upstream staging fix (unmap instead).
    Found with gdb on the QEMU gdbstub under TCG.

## Not covered by this acceptance

- The DESIGN-0001 M3 row also asks for a "refusal log empty or only by-design rows".
  This image has no driver silo, so there is no refusal log. That clause is N/A here and
  becomes testable once DS0 runs inside the M3 image.
- The root is read-only; writes go to the ramfs `/tmp`. A writable ext2 root needs the
  M2 allocation logic behind vfscore's create and write vnops, which is future work.
