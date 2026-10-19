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


## M-SPAWN-MMU (local until Q33)

When `CONFIG_LIBUKPAGING` is set, `mmu.c` is linked. `ksp_seal` derives a
per-child page table from `mem:` / `obj:` grants (`ksp_grant_mem`). Revoke
unmaps + TLB flush. Verb `cow` is the dissected-fork AS-copy grant.
(Superseded: seal now always derives a child PT.) Direct map and non-image frames are
stripped from every child PT (`ksp_mmu_strip_directmap`, `ksp_mmu_strip_nonimage`,
`ksp_mmu_census`). A child page fault on an ungranted address becomes a real SIGSEGV
(CR3 exception hooks + `ksp_mmu_pf_child`; needs `experiments/m-spawn-mmu/patches/unikraft-0.21-except-cr3-hooks.patch`). See
`experiments/m-spawn-mmu/`.

## M-SPAWN-MMU gaps (2026-10-19)

Gaps 1–3 PASS 3/3 under TCG (`experiments/m-spawn-mmu/`). Spawn acceptance: **not yet ready (gaps listed)** (review of `d1dc650`: R1 open, DESIGN-0001 §8.6.7d), not accepted. ELF child-CR3 via kernel-half + syscall CR3 leave (see experiments/m-spawn-mmu/README.md).
