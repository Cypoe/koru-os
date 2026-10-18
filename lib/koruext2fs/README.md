# koruext2fs: ext2 read path for Unikraft vfscore (B7)

| file | role |
|---|---|
| `ext2core.zig` | On-disk logic in Zig, freestanding and allocation-free, with a C ABI (`ext2c_*`). Block I/O comes in through a callback, so the same code runs in the unikernel and in host tests. |
| `ext2fs_vfs.c` | vfscore glue, registered as filesystem `koruext2`. Uses ukblkdev submit-and-reap with no queue callback (the same access sequence as koru-libs `unikraft/blk`). A 1 MiB direct-mapped block cache sits in front of the device, with read-ahead runs of up to 32 blocks. |
| `Makefile.uk` | Included from an application's `Makefile.uk`; it adds the glue and `build/libext2core.a`. |
| `build-core.sh` | Builds `build/libext2core.a`: x86_64-freestanding, ReleaseSafe, no red zone, no stack protector or probe. |
| `tests/` | `walk.zig` walks an image through the core and compares every entry with the source directory the image was built from (`mke2fs -d`). `run-host-tests.sh` runs it over six geometries plus one ext4 refusal. |

**Scope** (read-only by construction):
- rev 0/1, block size 1, 2 or 4 KiB, any number of groups;
- direct blocks plus single, double and triple indirect blocks, and holes;
- fast and slow symlinks;
- incompat FILETYPE only. Any other incompat feature (e.g. ext4 extents) is refused at mount with EOPNOTSUPP;
- every vnop that would write returns EROFS.

The fstab device string is the ukblkdev id ("" or "0").

**Relation to `koru/ext2`.** `koru/ext2` (M2) is the Koru lift that *allocates and writes*: phantom-typed mount, create and unmount. This library is the *read* path that vfscore needs. The two currently duplicate the superblock and inode parsing. Making the Koru lift call `ext2core.zig` from its procs is recorded debt (DESIGN-0001 §0.4, M3 row).

**Host tests** (`tests/host-tests-output.txt`, M, 2026-10-18): 7/7 PASS.
- Six ext2 images: 1 KiB with no features, 1 KiB with filetype, 1 KiB with 5 groups and sparse_super, 2 KiB with 2 groups and large_file, 4 KiB, and 4 KiB with no features.
- Each image holds 310 entries: a 5 MB double-indirect file, a sparse file, 300 directory entries spanning several blocks, a fast and a slow symlink, and an empty file.
- The ext4 image is refused, and its sha256 is unchanged.
