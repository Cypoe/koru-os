# M5a: dynamic linking from the ext2 root (DESIGN-0001 "M5a acceptance")

**Result (M, TCG only, 2026-10-19 13:06–13:08 CEST): PASS 3/3**, all checks (m1)–(m8), (d)
and (x). The M3 acceptance and the M4 stand-in (a)–(d) were rerun on the same kernel: each
passed 3/3 (13:07–13:09 CEST, `evidence/regress-*`).

## What runs
- **Kernel.** The M3/M4 arm, built by `../m3-ext2root/build-image.sh` with
  `KORU_REFUSAL_LOG=1`. It carries B6/B8/B9/B10 and the refusal-log patches, plus **B12**
  (`CONFIG_STACK_SIZE_PAGE_ORDER=7`). sha256 `72c054b4…`, 641,264 B.
- **Init shell.** busybox 1.37.0 as a **dynamically linked** glibc PIE (sha256 `145bf0e5…`),
  built by `build-inputs.sh`. It is interactive on the serial console. Every applet,
  including the pipeline `ls / | wc -l`, goes through `/lib64/ld-linux-x86-64.so.2`.
- **Loaders.** glibc 2.41 (Debian 13) and musl 1.2.5 (`/lib/ld-musl-x86_64.so.1`), each
  side-loaded by app-elfloader from `PT_INTERP`.
- **GNU coreutils 9.7** from the build host: `ls`, `wc`, `sha256sum`, `sort`, `head`, with
  libselinux, libcap, libpcre2, libcrypto 3, libz and libzstd (`libs.txt`).
- **Test programs.** `hello.c` built for musl and for glibc (dynamic PIE).
- Nothing in the image is committed: no GPL binaries, no libraries, no disk image.

Reproduce: `./build-inputs.sh /workspace/m5in`, then `./run-m5.sh <kernel> /workspace/m5in <outdir>`.

## Measurements

| run | QEMU wall (incl. 8 × 3 s scripted pauses) | checks | refusal rows (all classified) |
|---|---|---|---|
| 1 | 31.017 s | (m1)–(m8), (d), (x) PASS | 48 rows, 8 names |
| 2 | 31.018 s | same | same |
| 3 | 31.020 s | same | same |

Values seen in every run:
- musl and glibc hello both exit 42.
- `ls /` lists `bin dev etc lib lib64 lost+found tmp usr`.
- GNU and busybox `ls / | wc -l` both give 8.
- `sha256sum /etc/m5-data` = `f8cf211a…`, equal to the host.
- `sort | head -3` equals the host output.
- `exit 5` is reported as `init exited with status 5`.
- The disk is byte-identical across the boot, and `e2fsck` is clean.

Refusal rows: `brk`, `rseq`, `set_robust_list`, `statx` (`-ENOSYS`, with glibc fallbacks);
`STUBBED` `prctl`, `sched_getaffinity` (reports CPU0), `uk_posix_clone_sysvsem`; and
`prlimit64 resource 5` (RLIMIT_RSS refused, which GNU sort survives). `statx`,
`sched_getaffinity` and resource 5 first appeared in the uncounted trial boot. They were
classified before the counted runs (`refused-by-design.txt`).

## Found on the way
- **B12.** Programs started by `execve()` had a 64 KiB stack, and GNU `wc` overflowed it.
  This was already true in M3, where it went unnoticed because static busybox fits.
- In the first trial the harness lacked `libcrypto.so.3`, and the expected `ls` listing
  lacked `lost+found`. Both were harness bugs, fixed before the counted runs.

## Not covered (M5 proper)
A musl-built busybox, `dlopen`, pthreads, and `fork`-based `ash` (Q19; hush is the NOMMU/vfork
shell). B11, a vfork child that `_exit`s without exec, is still open.
