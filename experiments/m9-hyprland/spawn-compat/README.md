# Hyprland spawn-compat (Q30 stage 1 + stage 2)

## Choice (2026-10-19, Europe/Berlin CEST)

Hyprland 0.56.2 `Config::Supplementary::CExecutor::spawnRawProc` uses `fork` +
`execl("/bin/sh", "-c", cmd)`. Unikraft refuses `clone` without `CLONE_VM`, so the
frozen M9 trigger failed (B20).

**Least-invasive path chosen:** `LD_PRELOAD=libhypr-spawn-compat.so` interposes
`fork`. When the return address lies inside `spawnRawProc` (PIE offset
`0x527940`…`0x5280f0` on the Debian `hyprland_0.56.2+ds-3` binary, BuildID
`791ffc11…`), the interposer reads the command from Hyprland's `%rbp` (it holds
`&std::string`), `posix_spawnp`s a **simple** argv (no `/bin/sh`), and returns the
child pid so Hyprland takes its parent path. Complex shell lines (`&&`, `|`, …)
are refused loudly (`spawn-compat: REFUSED`). No text `mprotect` / hotpatch
(that path SIGSEGVs under this Unikraft build).

Hardware caps remain **M-SPAWN-MMU**.

A rebuilt hyprutils `CProcess::runAsync` → `posix_spawn` was prototyped but **not**
shipped into the M9 root: Hyprland's exec dispatcher does not use hyprutils for
`exec`; shipping a host-built `libhyprutils.so` also risked ABI skew with the
forky Hyprland binary.

## Q30 stage 2 (explicit `hyprland.children` grants)

Stage 1 used a **posix-inherit** bag for every simple spawn. Stage 2 replaces that
for the declared foot policy with an explicit grant manifest (still userspace /
seam-level; not MMU):

| Grant | What foot gets |
|---|---|
| env allowlist | `WAYLAND_DISPLAY`, `XDG_*`, `HOME`, `PATH`, `LANG`, `SHELL`, `LIBSEAT_BACKEND`, `HYPRLAND_INSTANCE_SIGNATURE`, plus `KORU_CHILD_ROLE=foot` and `LD_PRELOAD` so the path gate stays |
| fd bag | parent open fds closed (only live `F_GETFD≥0`); stdio → `/dev/null`; Wayland / korupty reach foot via path opens under the allowlist, not by inheriting Hyprland's fds |
| path gate | child-side `open`/`openat` interposer; prefixes under `/usr`, `/lib`, fonts, `/dev/korupty*`, `/dev/dri`, `/tmp/xdg`, … — **not** `/tmp/ungranted-secret` |

Unknown simple commands keep the **loud** `posix-inherit` fallback
(`policy=posix-inherit`). Foot logs `policy=hyprland.children` and
`why=hyprland.children` grant lines.

### Negatives (measured)

Before spawning foot the interposer plants an ungranted fd and
`/tmp/ungranted-secret`. The child `.so` (role=foot) writes `/tmp/rights-census.txt`:

- `negative_ungranted_path_eacces=1` — open of the secret returns `EACCES`
- `negative_ungranted_fd200_ebadf=1` — planted fd is not in the child
- `fd_open_count` small (≤8; no inherited bag)

Host check: `experiments/m9-hyprland/check-q30-stage2.py <rundir>`.

Evidence: `evidence/accept-q30s2-run-{1,2,3}/` — M9 CHECKS PASS + STAGE2 CHECKS PASS 3/3 under TCG.

## Build

```bash
gcc -shared -fPIC -O2 -o libhypr-spawn-compat.so hyprland_spawn_compat.c -ldl
```

Install as `/lib/libhypr-spawn-compat.so` in the guest root; `m9-accept-init`
starts Hyprland with `LD_PRELOAD=/lib/libhypr-spawn-compat.so`.

## foot / B21

foot's own shell spawn still forks. For M9, Hyprland execs
`/usr/bin/foot --pty=/dev/korupty0` with the korupty slave already running a
shell, so foot does not fork. Foot is Hyprland-launched (not the old init `&`
workaround). `M9_FOOT_PTY=1` re-enables the init workaround for debugging.
