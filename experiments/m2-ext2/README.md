# M2 / DoD-1: an allocating ext2 driver as a Koru lift

**Result: PASS under TCG (M), 2026-10-18 about 19:55 CEST. 3 of 3 runs with `-O none`,
plus 1 run with `filetype,sparse_super`.**

## Decision (recorded in DESIGN-0001 §0.3)
| route | finding (2026-10-18) | verdict |
|---|---|---|
| lwext4 under vfscore | no `unikraft/lib-lwext4` is reachable (the GitHub URL asks for auth, so it is private or missing). Upstream `gkostka/lwext4` @ `58bcf89a` (2022-09-22) is GPL-2.0 by default, which R-SILO-1 keeps out of the core image. `unikraft/lib-fatfs` @ `a4a21c8e` is an empty initial commit. The Unikraft 0.21.0 core has no ext or FAT | rejected for the core; possible later inside a GPL silo |
| LKL silo (DS1) | needs an LKL host port to Unikraft (D, Q25) | too large for M2 |
| **minimal ext2 as a Koru lift over ukblkdev** | own code, no licence question, uses the already-measured blk path | **chosen** |

## What the driver does (`koru/ext2/index.kz`)
- `mount` reads and validates the superblock. It requires rev 1, 1 KiB blocks, 128-byte
  inodes and one group. It accepts the incompat flag FILETYPE only and the ro_compat
  flags SPARSE_SUPER and LARGE_FILE only, and refuses anything else by name.
- `create` does the following, then flushes:
  - takes the first free inode at or above `first_ino` from the inode bitmap, and *n*
    free blocks from the block bitmap;
  - writes the data blocks and the inode (direct blocks only, ≤ 12 KiB);
  - splits the last entry of the root directory block to add the new entry;
  - sets the bitmap bits;
  - decrements the free counts in the group descriptor and the superblock.
- `verify` reads the file back. `unmount` stops and unconfigures the device.
- Phantom state: `mount` mints `<mounted!>`, `create`/`verify` need `<!mounted>` and
  mint it again, and `unmount` discharges it.

## Acceptance (`run.sh`)
1. On the host, `mke2fs -t ext2 -b 1024 -I 128 -N 64 -O none` creates a 4 MiB image, and
   `e2fsck -fn` before the run is clean.
2. The guest creates `/dod1` (10,000 bytes, a deterministic pattern) and reads it back.
3. Pass requires all of the following on the host:
   - `e2fsck -fn` exit 0 (all 5 passes, no fixes proposed);
   - `debugfs -R "cat /dod1"` byte-equal to the pattern;
   - free blocks drop by ≥ 10 and free inodes drop by exactly 1;
   - the guest prints `M2 guest: complete`.

## Measured (M)
| | value | evidence |
|---|---|---|
| e2fsck -fn after the guest write | exit 0, `12/64 files, 36/4096 blocks` | `evidence/run-1/after-e2fsck.txt` |
| debugfs read-back | 10,000 B, equal | `evidence/run-*/run.txt` |
| allocation | inode 12, blocks 26–35; free blocks 4070 → 4060, free inodes 53 → 52 | `evidence/run-1/` |
| `filetype,sparse_super` image | PASS (free blocks 4054 → 4044) | `evidence/run-ft/` |
| ext4 image | mount refused (`unsupported incompat feature`), image sha256 unchanged | `evidence/refusal-ext4/` |
| image / Koru archive | 194,176 B / 18,584 B | `evidence/sizes.txt` |
| QEMU wall time (TCG) | 0.260 / 0.251 / 0.233 s | `evidence/run-*/run.txt` |
| tools | e2fsprogs 1.47.2 | `evidence/e2fsprogs-version.txt` |

## Limits and debt (honest)
- **Single file, single directory block, single group, direct blocks.** This is the
  smallest real allocating driver, not a general filesystem. Missing: delete, growth,
  multiple groups, indirect blocks, and vfscore integration (needed for M3, where
  programs `open()` files).
- **Timestamps** are set to 1 (no clock is read). **mke2fs** warns that 128-byte inodes
  are deprecated (2038 limit).
- **No crash consistency.** The write order is data, inode, directory, bitmaps, group
  descriptor, superblock, flush, with no journal.
- **Error paths:** a `mount` refused after `uk_blkdev_start` does not unconfigure the
  device.
- **Duplication:** `ukblkdev` access is copied from `unikraft/blk`, because that lift
  exposes no byte-level API to other lifts.
