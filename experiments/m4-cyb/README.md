# M4: T-CYB with the labelled STAND-IN (DESIGN-0001 §0.2 "M4 acceptance for the stand-in")

**Result (M, TCG only, 2026-10-19 12:55 CEST): (a)–(d) and (x) pass 3/3; (e) open.** This is
not a full T-CYB pass. The program is a STAND-IN, not boot-animator (Q18, B3).

## What runs
- Arm: Unikraft 0.21.0 + app-elfloader + `koruext2fs` read-only ext2 root (the M3 arm), built by
  `../m3-ext2root/build-image.sh` with `KORU_REFUSAL_LOG=1`. Patch set: B6 vfork FSBASE, B6
  elfloader empty argv, B8 virtio ring, **B9** SIGCHLD/kill wakeups, **B10** `clock_nanosleep`,
  plus the two refusal-log patches (syscall-shim `-ENOSYS`, `UK_WARN_STUBBED`). Kernel sha256
  `ebe189b7…` (641,264 B).
- `/bin/ascii-animator`: `standin/` (Rust, `x86_64-unknown-linux-musl` static-PIE, sha256
  `c4e5583b…`), wrapping plex-libs `anim.rs` copied verbatim (sha256 `9b671ec2…`).
- `/assets/80x24.anim`: plex-os `boot.anim` (sha256 `b7de2964…`) re-cut by `recut.py`
  (175 frames, 24 fps, leftmost 80 columns × 24 rows; sha256 `f49dfebc…`).
- `/etc/t-cyb-init` under hush: start `&`, `sleep 3`, `kill -USR1`, `wait`, exit with its status.
- Build inputs come from the private plex-shell checkout at build time; `anim.rs`, the asset,
  binaries, disk images and screendumps are not committed.

Reproduce: `./build-standin.sh <plex-shell> /workspace/m4build`, build the kernel, then
`./run-m4.sh <kernel> <static-pie busybox> /workspace/m4build <outdir>`.

## Measurements (set 2, the counted set)

| run | QEMU wall (boot → poweroff) | frames shown, all asset-identical and in order | animator's own time to SIGUSR1 | (d) rows |
|---|---|---|---|---|
| 1 | 3.449 s | 73 | 3.020 s | 12 ENOSYS + 2 STUBBED, all classified |
| 2 | 3.439 s | 73 | 3.020 s | same |
| 3 | 3.430 s | 73 | 3.021 s | same |

73 frames in 3.02 s is the asset's 24 fps (frame 0 at t = 0). `Detected TTY size: 80x24` came
from `TIOCGWINSZ` in the guest (the L1 run, with stdout redirected to a file, used the
default). The disk was byte-identical before and after every boot, and `e2fsck -fn` stayed clean.

Refusal log (d), classified in `refused-by-design.txt`: `brk`, `rseq`, `set_robust_list`
(`-ENOSYS`, glibc startup in busybox), `STUBBED __uk_syscall_r_prctl` (busybox task name),
`STUBBED uk_posix_clone_sysvsem` (kernel-internal, before any user program runs). The stand-in
itself produced no refusal row.

**Set 1 (12:54 CEST) failed (d) 3/3.** It was the first run with the stubbed-call log, and
`STUBBED uk_posix_clone_sysvsem` was not yet classified. Everything else passed. The row was
classified at 12:57 CEST, and set 2 was then run unchanged. Both sets are in `evidence/`.

## (e) screendump
A mid-run QEMU `screendump` (720×400 VGA text) was taken in every run and kept on the box. As
predicted in DESIGN-0001, it shows CP437 mojibake: each UTF-8 `░` (E2 96 91) is drawn as
`Γûæ`, and `ESC[K` appears as `←[K`. (e) stays open until there is a display path that decodes
UTF-8.

## Bugs found on the way (BLOCKERS.md)
- **B9.** Without it, hush `wait` on a background job hangs forever.
- **B10.** Without it, the stand-in never sleeps. On the cooperative scheduler hush then never
  runs. The trial boot spewed about 4,000 frames in 90 s and was killed by the timeout.
- **B11 (open).** A crash after a vfork child `_exit()`s without exec. It is not on this path.

## L1
`evidence/l1/l1-result.txt`: the same binary on the box kernel (6.12.94+), with SIGUSR1 after
1 s under `strace -f`. It showed 25 frames, exit 0, and 22 distinct syscalls, including
`clock_nanosleep(CLOCK_MONOTONIC)`, the call B10 was about. That is the stand-in's DoD-2 row list.
