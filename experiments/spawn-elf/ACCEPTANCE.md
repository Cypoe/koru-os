# Spawn + Unikraft provider + loud compat: acceptance (frozen before counted runs)

Criteria frozen 2026-10-19 19:58:10 CEST, before the counted E0-E12 boots of the
built image. The freeze commit is this push. DESIGN-0001 sections 8.6.2-8.6.4,
8.6.6, 8.6.7 (Q32).

**In scope:** `lib/koruspawn` (Unikraft provider) + `lib/koruelf` (forked
app-elfloader load path, Q32) + loud compat (`spawn-compat:` lines). An external
static-pie ELF (`experiments/spawn-elf/child/hello.c`, built with zig/musl at
image build time; the binary is not committed) is started via Spawn with an
explicit rights bag. QEMU TCG only.

**Also covered in the Koru lift** (`koru/spawn`, measured as S1-S13): replace
(across_exec), detach, revoke (epoch per section 8.5), nested attenuation
(`authority-of`).

| id | criterion |
|----|-----------|
| E1 | begin/done |
| E2 | fork refused (F2) with spawn-compat line |
| E3 | empty bag: child exit status 0 (nopen encoded; no stdout) |
| E4 | empty bag: no child: print lines |
| E5 | grants: child sees fd/1 and TERM=xterm-spawn |
| E6 | address-space grant refused |
| E7 | path /etc/passwd refused at the vfscore path gate |
| E8 | revoke: epoch marked, writes refused at the proxy |
| E9 | replace from parent refused (EPERM) |
| E10 | detach: reap obligation moves; wait returns ECHILD |
| E11 | posix_spawn compat lines with why=posix-inherit |
| E12 | vfork+execve compat; roster 0 at end |
| E0 | no CRIT/crash, no child: FAIL |

PASS = E0-E12 in 3/3 boots of one image. M9 / Hyprland untouched (Q30).
Concordance terms proposed only.

## M-SPAWN-MMU gaps (2026-10-19)

Gaps 1–3 PASS 3/3 under TCG (`experiments/m-spawn-mmu/`). Spawn acceptance: **ready for Fabian review**, not accepted. ELF child-CR3 remaining (see DESIGN-0001 M-SPAWN-MMU row).
