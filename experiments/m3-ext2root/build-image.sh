#!/usr/bin/env bash
# M3 image with the ext2 root: app-elfloader + koruext2fs (vfscore) + exit-status hook,
# Unikraft 0.21 with the three koru-os patches. Reuses the sources kraft fetched for
# experiments/m3-busybox (W_SRC) so the patch set is identical; otherwise fetch first.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
W=${W:-/workspace/m3ext2}; W_SRC=${W_SRC:-/workspace/m3img}
P="$REPO/experiments/m3-busybox/patches"
export PATH=/workspace/tc/zig-x86_64-linux-0.15.2:/workspace/tc/kraft:$PATH
mkdir -p "$W" && cd "$W"
cp "$HERE/app/Kraftfile" "$HERE/app/Makefile.uk" "$HERE/app/Config.uk" "$HERE/app/exitstatus.c" .
rm -rf koruext2fs && mkdir koruext2fs
"$REPO/lib/koruext2fs/build-core.sh" >/dev/null
cp -r "$REPO/lib/koruext2fs/ext2fs_vfs.c" "$REPO/lib/koruext2fs/Makefile.uk" "$REPO/lib/koruext2fs/build" koruext2fs/
if [ ! -d .unikraft/unikraft ]; then
  [ -d "$W_SRC/.unikraft/unikraft" ] || { echo "run experiments/m3-busybox/build-image.sh first (fetches sources)"; exit 1; }
  mkdir -p .unikraft && cp -r "$W_SRC/.unikraft/unikraft" "$W_SRC/.unikraft/apps" "$W_SRC/.unikraft/libs" .unikraft/
fi
ap() { grep -q "koru-os" "$2" || patch -d "$1" -p1 < "$3"; }
ap .unikraft/unikraft .unikraft/unikraft/lib/posix-process/clone.c "$P/unikraft-0.21-posix-process-vfork-fsbase.patch"
ap .unikraft/unikraft .unikraft/unikraft/drivers/virtio/ring/virtio_ring.c "$P/unikraft-0.21-virtio-ring-destroy-vmem.patch"
ap .unikraft/apps/elfloader .unikraft/apps/elfloader/elf_ctx.c "$P/app-elfloader-empty-arg.patch"
# B9 (M4): SIGCHLD must wake a parent in rt_sigsuspend()/pause() (hush `wait`)
ap .unikraft/unikraft .unikraft/unikraft/lib/posix-process/exit.c "$P/unikraft-0.21-posix-process-sigchld-wake.patch"
# B10 (M4): clock_nanosleep(CLOCK_MONOTONIC / TIMER_ABSTIME) returned 0 without sleeping
ap .unikraft/unikraft .unikraft/unikraft/lib/posix-time/time.c "$P/unikraft-0.21-posix-time-clock-nanosleep.patch"
# M4 (refusal log, DESIGN-0001 §0.2 M4 (d)): KORU_REFUSAL_LOG=1 logs every syscall-shim -ENOSYS at error level
if [ "${KORU_REFUSAL_LOG:-0}" = 1 ]; then
  ap .unikraft/unikraft .unikraft/unikraft/lib/syscall_shim/include/uk/syscall.h "$P/unikraft-0.21-syscall-shim-enosys-log.patch"
  ap .unikraft/unikraft .unikraft/unikraft/lib/ukprint/include/uk/print.h "$P/unikraft-0.21-ukprint-stubbed-refusal-log.patch"
fi
rm -f .config.m3-ext2root_qemu-x86_64 .unikraft/build/config
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt --log-type basic
