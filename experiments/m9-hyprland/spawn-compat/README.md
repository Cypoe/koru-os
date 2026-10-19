# Hyprland spawn-compat (Q30 stage 1)

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

Stage 2 (Spawn supervisor / rights bags at the Hyprland seam) is **not** required
for M9 (h2a). Hardware caps remain **M-SPAWN-MMU**.

A rebuilt hyprutils `CProcess::runAsync` → `posix_spawn` was prototyped but **not**
shipped into the M9 root: Hyprland's exec dispatcher does not use hyprutils for
`exec`; shipping a host-built `libhyprutils.so` also risked ABI skew with the
forky Hyprland binary.

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
