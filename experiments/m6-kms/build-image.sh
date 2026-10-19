#!/usr/bin/env bash
# M6 image: the M5a arm (app-elfloader + koruext2fs root, Unikraft 0.21 with the koru-os
# patches B6/B8/B9/B10/B12 and the refusal log) plus lib/korukms (kms.* rows, native
# bochs-display provider, Linux DRM personality on /dev/dri/card0) and two M6 patches:
# devfs one-level subdirectories + st_rdev, and the posix-mmap device-memory hook.
# Sources come from the kraft fetch of experiments/m3-busybox (W_SRC), as in M3.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
W=${W:-/workspace/m6k}; W_SRC=${W_SRC:-/workspace/m3img}
P="$REPO/experiments/m3-busybox/patches"; P6="$HERE/patches"
export PATH=/workspace/tc/zig-x86_64-linux-0.15.2:/workspace/tc/kraft:$PATH
mkdir -p "$W" && cd "$W"
cp "$HERE/app/Kraftfile" "$HERE/app/Makefile.uk" "$HERE/app/Config.uk" "$HERE/app/exitstatus.c" .
rm -rf koruext2fs korukms && mkdir koruext2fs korukms
"$REPO/lib/koruext2fs/build-core.sh" >/dev/null
cp -r "$REPO/lib/koruext2fs/ext2fs_vfs.c" "$REPO/lib/koruext2fs/Makefile.uk" "$REPO/lib/koruext2fs/build" koruext2fs/
cp "$REPO"/lib/korukms/*.c "$REPO"/lib/korukms/*.h "$REPO/lib/korukms/Makefile.uk" korukms/
if [ ! -d .unikraft/unikraft ]; then
  [ -d "$W_SRC/.unikraft/unikraft" ] || { echo "run experiments/m3-busybox/build-image.sh first (fetches sources)"; exit 1; }
  mkdir -p .unikraft && cp -r "$W_SRC/.unikraft/unikraft" "$W_SRC/.unikraft/apps" "$W_SRC/.unikraft/libs" .unikraft/
fi
ap() { grep -q "koru-os" "$2" || patch -d "$1" -p1 < "$3"; }
U=.unikraft/unikraft
ap $U $U/lib/posix-process/clone.c "$P/unikraft-0.21-posix-process-vfork-fsbase.patch"
ap $U $U/drivers/virtio/ring/virtio_ring.c "$P/unikraft-0.21-virtio-ring-destroy-vmem.patch"
ap .unikraft/apps/elfloader .unikraft/apps/elfloader/elf_ctx.c "$P/app-elfloader-empty-arg.patch"
ap $U $U/lib/posix-process/exit.c "$P/unikraft-0.21-posix-process-sigchld-wake.patch"
ap $U $U/lib/posix-time/time.c "$P/unikraft-0.21-posix-time-clock-nanosleep.patch"
ap $U $U/lib/syscall_shim/include/uk/syscall.h "$P/unikraft-0.21-syscall-shim-enosys-log.patch"
ap $U $U/lib/ukprint/include/uk/print.h "$P/unikraft-0.21-ukprint-stubbed-refusal-log.patch"
# M6
ap $U $U/lib/devfs/devfs_vnops.c "$P6/unikraft-0.21-devfs-subdir-rdev.patch"
ap $U $U/lib/posix-mmap/mmap.c "$P6/unikraft-0.21-posix-mmap-device-hook.patch"
rm -f .config.m6-kms_qemu-x86_64 .unikraft/build/config
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt --log-type basic
