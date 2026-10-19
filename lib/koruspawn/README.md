# lib/koruspawn

Unikraft provider of `koruos/spawn` (DESIGN-0001 §8.6.7; home is koru-libs
`unikraft/spawn`, here until Q33) and the loud Linux-ABI compatibility layer
(§8.6.4).

## Q32

The ELF load path is a local fork of `unikraft/app-elfloader` (`elf_load.c`,
`elf_ctx.c`, `elf_binfmt.c`, headers) under `lib/koruelf/`. It is not a live
dependency on `apps/elfloader`. The fork carries the existing koru-os B6 empty-arg
patch. Updating it means re-copying from a pinned app-elfloader SHA and
re-applying that patch.

## Seam

- **fds:** every granted fd is a `koruspawn` proxy `uk_file`. Each use checks
  the grant's verbs and epoch (§8.5).
- **paths:** `vfscore` `task_conv` / `taskat_conv` call `koru_vfs_path_gate`
  (patch under `experiments/spawn-elf/patches/`).
- **env:** `install_bag` clears the environment and re-adds only `env/*` grants.

Rung 0/1: provenance and correctness at the seam, not a security boundary.
