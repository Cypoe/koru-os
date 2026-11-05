# lib/koruelf

Local, in-koru-os fork of the load path from `unikraft/app-elfloader`
(`elf_load.c`, `elf_ctx.c`, `elf_binfmt.c`, `elf_prog.h`, `libelf_helper.h`).
Recorded under DESIGN-0001 Q32. Source was copied from the kraft-fetched tree
used by `experiments/m3-busybox` (Unikraft 0.21 / app-elfloader `stable`), with
the koru-os B6 empty-arg patch already applied in `elf_ctx.c`.
