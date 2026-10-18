# M3 (started): static busybox on app-elfloader, Unikraft 0.21.0, QEMU TCG

Status: **superseded.** This was the partial M3 with an initrd root (about 20:00 CEST). B6 is fixed below;
the full M3 acceptance from the ext2 root is in `experiments/m3-ext2root/` (PASS 3/3). The original status line
read: the M3 acceptance in DESIGN-0001 §0.4 is not met yet.

## What runs (measured)

- **Interactive shell over serial.** busybox `hush` reads commands typed on COM1 and
  answers them (`run-session.sh` → `evidence/session-1.txt`). Each typed line shows up
  twice because the console echoes it and the line editor echoes it again.
- **Builtins**: echo, arithmetic, redirection into the ramfs (`echo koru > /tmp/f`).
- **External applets via vfork + execve through app-elfloader**:
  - `uname -a` prints "Unikraft unikraft 5.15.148-Ijiraq 0.21.0 x86_64 GNU/Linux";
  - `cat`, `date`, `id`, `wc`, `mkdir`, `ls /`, `ls /bin/a*`;
  - `sha256sum /bin/busybox` inside the guest equals the host hash of the binary
    (`7089e5d2…`).
- **Timing**: a boot-run-exit cycle with `sh -c` takes 0.36–0.53 s wall under TCG
  (`evidence/cases-1.txt`).

## What crashes (measured, reproducible)

Every **pipeline** (`true | true`, `echo x | cat`, `seq 3 | wc -l`) crashes. So does any
**external command whose stdout is redirected** (`ls /bin > /tmp/l`). The kernel reports
`Cannot deliver SIGSEGV for pf at 0xf` (pipelines) or `… at 0x308` (redirects). Builtins
with redirection work.

Hypothesis (`?`): the fault is in the vfork child of hush, which runs on the parent's
memory until execve. Setting up the redirection (dup2/close) before execve triggers it.
The next step is a minimal C reproducer (vfork, dup2, execve) on the same image. If it
reproduces, it is reported upstream; the alternative is a posix_spawn-style exec path.

## Route and decisions

- **Debian `busybox-static` does not load**: it is ET_EXEC, and app-elfloader requires
  PIE ("ELF executable is not position-independent"). Alpine's `busybox.static` is also
  ET_EXEC. So busybox 1.37.0 is built from source as glibc **static-pie**
  (`build-busybox.sh`, tarball sha256 checked).
- **Unikraft 0.21 has no `fork`** ("CLONE_VM not set: Multiple address spaces are not
  supported"), so ash cannot run. busybox is built `CONFIG_NOMMU=y`, with `hush` as `sh`
  and `BUSYBOX_EXEC_PATH=/bin/busybox` (no `/proc/self/exe`). `TC` and the SHA hardware
  acceleration are disabled.
- **Kconfig on top of `unikraft/catalog library/base`** (`Kraftfile`; lwip, 9p, netdev
  and netlink removed, LTO off):
  - `LIBPOSIX_PROCESS_MULTIPROCESS`, `_SIGNAL`, `_EXECVE` (otherwise `vfork` returns
    ENOSYS);
  - `LIBPOSIX_TTY_STDIN_SERIAL` (the default stdin returns EOF immediately);
  - `PATH=/bin` (the catalog PATH starts at `/usr/local/sbin`, and the first failed
    execve returns EINVAL rather than ENOENT, which stops the PATH search).
- **Rootfs**: an embedded initrd (cpio) extracted into ramfs, holding `/bin/busybox`,
  400 applet symlinks and `/tmp`. The ext2 lift from M2 is **not** under vfscore, so it
  is not the root filesystem yet.
- kraft keeps a stale `.config.<target>` across Kraftfile edits. `build-image.sh` deletes
  it before building.
- The busybox binary is **not committed** (GPL-2.0; it is reproducible from
  `build-busybox.sh` + `busybox.config`).

## Files

| file | content |
|---|---|
| `build-busybox.sh`, `busybox.config` | static-PIE NOMMU busybox build |
| `Kraftfile`, `build-image.sh` | the elfloader image |
| `qemu.sh` | TCG only (B1) |
| `run-session.sh`, `run-cases.sh` | the serial session and the one-boot-per-case matrix |
| `evidence/` | session and case logs, sizes, pins, relevant kconfig, kraft build tail |

Sizes: kernel 3,016,688 B including the embedded 2,410,696 B cpio; busybox 2,357,096 B.

## B6: root cause and fix (2026-10-18, about 20:10 CEST, M under TCG)

The reproducer `b6-repro/vrepro.c` is a static-pie glibc program. It calls vfork, then in
the child does one of nothing, open+dup2, pipe+dup2 or close, and then execv
`busybox echo`. Before the fix, only the plain vfork → execv case ran; the other three
crashed.

`qemu -d int` shows a #GP at `__internal_syscall_cancel+0xd`. That instruction is
`mov %fs:0x10,%rbx; mov 0x308(%rbx),%eax`: glibc 2.41 reads THREAD_SELF from its TCB.
In the vfork child, `%fs` pointed at the **Unikraft** TLS instead of glibc's TCB.

The cause is in `lib/posix-process/clone.c`. For CLONE_VFORK it sets
`child->tlsp = child->uktlsp`, which the scheduler switch needs. Then
`arch/x86_64/clone.c:clone_setup_child_ctx()` installs `child->tlsp` as the child's
*userland* FSBASE whenever it is non-zero. A plain execv in the child works only because
it never touches `%fs`. The upstream `stable` and `staging` branches have the same code
(checked 2026-10-18).

The fix is `patches/unikraft-0.21-posix-process-vfork-fsbase.patch`: for CLONE_VFORK,
build the child's return context with `tlsp` hidden, so the child keeps the parent's
userland FSBASE, then restore `tlsp`.

The second bug showed up once pipelines got further. hush on NOMMU re-execs itself for
builtins inside pipelines and passes empty argv strings. app-elfloader then hits
`UK_ASSERT(len)` in `infoblk_push`. The fix is `patches/app-elfloader-empty-arg.patch`:
an empty string is pushed as a lone NUL.

After both patches, `evidence/cases-2-b6-fixed.txt` shows all 23 cases running with no
crash. That includes pipelines (`echo hello | tr a-z A-Z | wc -c` → 6), redirected
external commands, command substitution, `sh -c "exit 3"; echo rc=$?` → `rc=3`, and all
four vrepro modes. `build-image.sh` applies the patches idempotently after kraft's first
fetch.
