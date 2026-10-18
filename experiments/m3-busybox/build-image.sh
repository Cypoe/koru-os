#!/usr/bin/env bash
# Pack busybox (+ applet symlinks, + the B6 reproducer) into the embedded initrd and build
# the elfloader image with the two koru-os B6 patches applied.
set -euo pipefail
W=${W:-/workspace/m3img}; BB=${BB:-/workspace/m3/busybox-1.37.0/busybox}; HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/workspace/tc/zig-x86_64-linux-0.15.2:/workspace/tc/kraft:$PATH
mkdir -p "$W" && cd "$W"
cp "$HERE/Kraftfile" Kraftfile
rm -rf rootfs && mkdir -p rootfs/bin rootfs/tmp && touch rootfs/tmp/.keep
cp "$BB" rootfs/bin/busybox
(cd rootfs/bin && for a in $(./busybox --list); do [ "$a" = busybox ] || ln -sf busybox "$a"; done)
gcc -O1 -g -fPIE -static-pie -o rootfs/bin/vrepro "$HERE/b6-repro/vrepro.c"
build() { rm -f .config.m3-busybox_qemu-x86_64 .unikraft/build/config
  UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt --log-type basic; }
# First build fetches unikraft + libs into .unikraft (kraft has no separate fetch step we rely on).
[ -d .unikraft/unikraft ] || build
grep -q "koru-os B6" .unikraft/unikraft/lib/posix-process/clone.c || \
  patch -d .unikraft/unikraft -p1 < "$HERE/patches/unikraft-0.21-posix-process-vfork-fsbase.patch"
grep -q "koru-os B6" .unikraft/apps/elfloader/elf_ctx.c || \
  patch -d .unikraft/apps/elfloader -p1 < "$HERE/patches/app-elfloader-empty-arg.patch"
build
