# Spawn-elf: external ELF child via Spawn (Unikraft provider + loud compat)

DESIGN-0001 §8.6.4 / §8.6.7. Provider: `lib/koruspawn`. ELF load path: `lib/koruelf`
(Q32: local fork of app-elfloader load files; not a live apps/elfloader dependency).

## Result (2026-10-19, M under QEMU TCG)

- E0–E12 PASS in 3/3 boots (`evidence/`).
- Checker mutation: changing nopen / revoke reason makes E5/E8 FAIL.
- An external static-pie musl ELF is reserved, granted an explicit bag, sealed, started,
  waited and reaped. Empty-by-default, revoke (epoch), detach, replace-from-parent
  refusal, path gate, and `spawn-compat:` lines for posix_spawn / vfork+execve / fork
  are measured.

## Q32

`lib/koruelf/` holds `elf_load.c`, `elf_ctx.c`, `elf_binfmt.c` and headers copied from
the kraft-fetched app-elfloader used by M3, with the koru-os B6 empty-arg patch. Updating
means re-copying from a pinned SHA and re-applying that patch.

## Concordance

Proposed only: spawn, grant, rights bag, seal, authority, seam, ambient set, abandon,
replace, detach, revoke, across_exec, nested attenuation. Cite Cypoe/koru ccomp
`docs/concordance-matrix.md` (a1218e1f / tip b39a442f). No second matrix.

M9 and Hyprland are not touched (Q30 open).
