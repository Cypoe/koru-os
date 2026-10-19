#!/usr/bin/env bash
# M7 image: the M6 image (M5a arm + lib/korukms + the two M6 patches) plus lib/koruinput
# (input.* rows, native i8042 PS/2 keyboard provider, Linux evdev personality on
# /dev/input/event0) and two M7 patches: devfs poll dispatch + O_NONBLOCK to device read,
# and the posix-poll fix for vfscore (legacy) epoll entries (epf was never set).
# M7b: lib/korusysfs (minimal sysfs view on /sys, written by providers and personalities).
# Sources come from the kraft fetch of experiments/m3-busybox (W_SRC), as in M3.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
W=${W:-/workspace/m7k}; W_SRC=${W_SRC:-/workspace/m3img}
P="$REPO/experiments/m3-busybox/patches"; P6="$REPO/experiments/m6-kms/patches"; P7="$HERE/patches"
export PATH=/workspace/tc/zig-x86_64-linux-0.15.2:/workspace/tc/kraft:$PATH
mkdir -p "$W" && cd "$W"
cp "$HERE/app/Kraftfile" "$HERE/app/Makefile.uk" "$HERE/app/Config.uk" "$HERE/app/exitstatus.c" .
rm -rf koruext2fs korukms koruinput korusysfs korusnap korupty korumemfd && mkdir koruext2fs korukms koruinput korusysfs korusnap korupty korumemfd
"$REPO/lib/koruext2fs/build-core.sh" >/dev/null
cp -r "$REPO/lib/koruext2fs/ext2fs_vfs.c" "$REPO/lib/koruext2fs/Makefile.uk" "$REPO/lib/koruext2fs/build" koruext2fs/
cp "$REPO"/lib/korukms/*.c "$REPO"/lib/korukms/*.h "$REPO/lib/korukms/Makefile.uk" korukms/
cp "$REPO"/lib/koruinput/*.c "$REPO"/lib/koruinput/*.h "$REPO/lib/koruinput/Makefile.uk" koruinput/
cp "$REPO"/lib/korusysfs/*.c "$REPO"/lib/korusysfs/*.h "$REPO/lib/korusysfs/Makefile.uk" korusysfs/
cp "$REPO"/lib/korusnap/*.c "$REPO/lib/korusnap/Makefile.uk" korusnap/ # M9
cp "$REPO"/lib/korupty/*.c "$REPO/lib/korupty/Makefile.uk" korupty/ # M9
cp "$REPO"/lib/korumemfd/*.c "$REPO/lib/korumemfd/Makefile.uk" korumemfd/ # M9
if [ ! -d .unikraft/unikraft ]; then
  [ -d "$W_SRC/.unikraft/unikraft" ] || { echo "run experiments/m3-busybox/build-image.sh first (fetches sources)"; exit 1; }
  mkdir -p .unikraft && cp -r "$W_SRC/.unikraft/unikraft" "$W_SRC/.unikraft/apps" "$W_SRC/.unikraft/libs" .unikraft/
fi
ap() { grep -q "${4:-koru-os}" "$2" || patch -d "$1" -p1 < "$3"; }
U=.unikraft/unikraft
ap $U $U/lib/posix-process/clone.c "$P/unikraft-0.21-posix-process-vfork-fsbase.patch"
ap $U $U/drivers/virtio/ring/virtio_ring.c "$P/unikraft-0.21-virtio-ring-destroy-vmem.patch"
ap .unikraft/apps/elfloader .unikraft/apps/elfloader/elf_ctx.c "$P/app-elfloader-empty-arg.patch"
ap $U $U/lib/posix-process/exit.c "$P/unikraft-0.21-posix-process-sigchld-wake.patch"
ap $U $U/lib/posix-time/time.c "$P/unikraft-0.21-posix-time-clock-nanosleep.patch"
ap $U $U/lib/syscall_shim/include/uk/syscall.h "$P/unikraft-0.21-syscall-shim-enosys-log.patch"
ap $U $U/lib/ukprint/include/uk/print.h "$P/unikraft-0.21-ukprint-stubbed-refusal-log.patch"
# M6
ap $U $U/lib/devfs/devfs_vnops.c "$P6/unikraft-0.21-devfs-subdir-rdev.patch" "koru-os M6"
ap $U $U/lib/posix-mmap/mmap.c "$P6/unikraft-0.21-posix-mmap-device-hook.patch"
# M7
ap $U $U/lib/devfs/devfs_vnops.c "$P7/unikraft-0.21-devfs-poll-nonblock.patch" "koru-os M7"
ap $U $U/lib/posix-poll/epoll.c "$P7/unikraft-0.21-posix-poll-legacy-epf.patch"
# M7b
P7B="$REPO/experiments/m7b-libinput/patches"
ap $U $U/lib/vfscore/main.c "$P7B/unikraft-0.21-vfscore-fstatat-nofollow.patch" "koru-os M7b"
# M9
P9="$REPO/experiments/m9-hyprland/patches"
ap .unikraft/apps/elfloader .unikraft/apps/elfloader/elf_load.c "$P9/app-elfloader-execve-errno.patch" "koru-os: use the raw syscall"
ap $U $U/lib/posix-fdtab/fdtab.c "$P9/unikraft-0.21-posix-fdtab-scm-refs.patch" "koru-os M9"
ap $U $U/lib/posix-unixsocket/unixsock.c "$P9/unikraft-0.21-posix-unixsocket-scm-rights.patch" "koru-os M9"
ap $U $U/lib/posix-unixsocket/unixsock-bind.c "$P9/unikraft-0.21-posix-unixsocket-pathname-nul.patch" "koru-os M9"
ap $U $U/lib/devfs/devfs_vnops.c "$P9/unikraft-0.21-devfs-truncate-size.patch" "koru-os M9"
ap $U $U/lib/posix-poll/epoll.c "$P9/unikraft-0.21-posix-poll-epoll-sigmask.patch" "koru-os M9"
ap $U $U/lib/posix-poll/poll.c "$P9/unikraft-0.21-posix-poll-ppoll-sigmask.patch" "koru-os M9"
ap $U $U/lib/vfscore/main.c "$P9/unikraft-0.21-vfscore-devshm.patch" "koru-os M9"
ap $U $U/lib/posix-mmap/mmap.c "$P9/unikraft-0.21-posix-mmap-device-refusal.patch" "a device that refuses"
rm -f .config.m7-input_qemu-x86_64 .unikraft/build/config
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt --log-type basic
