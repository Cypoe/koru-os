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

Gaps 1–3 PASS 3/3 under TCG (`experiments/m-spawn-mmu/`).

## ELF child-CR3 (2026-10-19 ~22:17 CEST)

External ELF runs on **child CR3** (kernel-half + syscall/IRQ CR3 leave). E0–E12 plus M
(hw parent-heap fault + RO attenuation under child CR3) PASS 3/3
(`evidence/elf-cr3-accept/`). Spawn acceptance: **not yet ready (gaps listed)** (review of `d1dc650`: R1 open, DESIGN-0001 §8.6.7d), not accepted.

## Review gaps R2/R3 (2026-10-19 ~22:45 CEST)

`evidence/elf-gap23-accept/run-{1,2,3}/`: SPAWN-ELF PASS 3/3. New checks: G2 (direct-map
slot stripped; census undeclared=0 at derive and gate; non-image leftovers stripped; alias
readable in parent, faults in child) and G3 (7 touch cases → status 139 / WTERMSIG=11 with
a logged `reason=mmu-violation` line, including `directmap-alias` and
`parent-mapped-ungranted`; RO-grant read survives; 20 ms sleep then touch → SIGSEGV; no
kernel-context fault). `elf-cr3-accept/` (d1dc650) predates the latent IRQ-CR3 bug fix.
