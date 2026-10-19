#!/usr/bin/env bash
# Build the spawn-elf image: koruspawn + koruelf + hello child on initrd.
# Sources come from the kraft fetch of experiments/m3-busybox (W_SRC).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
W=${W:-/workspace/spelf}; W_SRC=${W_SRC:-/workspace/m3img}
P="$REPO/experiments/m3-busybox/patches"; PELF="$HERE/patches"
export PATH=/workspace/tc/zig-x86_64-linux-0.15.2:/workspace/tc/kraft:$PATH
mkdir -p "$W" && cd "$W"
cp "$HERE/app/Kraftfile" "$HERE/app/Makefile.uk" "$HERE/app/Config.uk" "$HERE/app/main.c" .
rm -rf koruspawn koruelf rootfs
mkdir -p koruspawn koruelf rootfs/bin
cp "$REPO"/lib/koruspawn/* koruspawn/
cp "$REPO"/lib/koruelf/* koruelf/
"$HERE/build-child.sh" "$W/rootfs/bin/hello"
# tiny /tmp
mkdir -p rootfs/tmp && touch rootfs/tmp/.keep
# also stage a fake /etc/passwd so the child's access() has something to refuse
mkdir -p rootfs/etc && echo "root:x:0:0:root:/:/bin/sh" > rootfs/etc/passwd

if [ ! -d .unikraft/unikraft ]; then
  [ -d "$W_SRC/.unikraft/unikraft" ] || { echo "run experiments/m3-busybox/build-image.sh first"; exit 1; }
  mkdir -p .unikraft && cp -r "$W_SRC/.unikraft/unikraft" "$W_SRC/.unikraft/libs" .unikraft/
  # do NOT copy apps/elfloader — we use lib/koruelf
fi
ap() { grep -q "koru-os" "$2" 2>/dev/null || patch -d "$1" -p1 < "$3"; }
U=.unikraft/unikraft
ap $U $U/lib/posix-process/clone.c "$P/unikraft-0.21-posix-process-vfork-fsbase.patch"
ap $U $U/drivers/virtio/ring/virtio_ring.c "$P/unikraft-0.21-virtio-ring-destroy-vmem.patch"
ap $U $U/lib/posix-process/exit.c "$P/unikraft-0.21-posix-process-sigchld-wake.patch"
ap $U $U/lib/posix-time/time.c "$P/unikraft-0.21-posix-time-clock-nanosleep.patch"
ap $U $U/lib/syscall_shim/include/uk/syscall.h "$P/unikraft-0.21-syscall-shim-enosys-log.patch"
ap $U $U/lib/ukprint/include/uk/print.h "$P/unikraft-0.21-ukprint-stubbed-refusal-log.patch"
ap $U $U/lib/vfscore/task.c "$PELF/unikraft-0.21-vfscore-spawn-path-gate.patch"
ap $U $U/lib/uksched/include/uk/sched_impl.h "$REPO/experiments/m-spawn-mmu/patches/unikraft-0.21-sched-cr3-switch.patch"

rm -f .config.spawn-elf_qemu-x86_64 .unikraft/build/config
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt --log-type basic
ls -la .unikraft/build/spawn-elf_qemu-x86_64
