#!/usr/bin/env bash
# Pack busybox + applet symlinks into the embedded initrd and build the elfloader image.
set -euo pipefail
W=${W:-/workspace/m3img}; BB=${BB:-/workspace/m3/busybox-1.37.0/busybox}; HERE=$(cd "$(dirname "$0")" && pwd)
export PATH=/workspace/tc/zig-x86_64-linux-0.15.2:/workspace/tc/kraft:$PATH
mkdir -p "$W" && cd "$W"
cp "$HERE/Kraftfile" Kraftfile
rm -rf rootfs && mkdir -p rootfs/bin rootfs/tmp && touch rootfs/tmp/.keep
cp "$BB" rootfs/bin/busybox
(cd rootfs/bin && for a in $(./busybox --list); do [ "$a" = busybox ] || ln -sf busybox "$a"; done)
# kraft keeps a stale .config.<target> across Kraftfile edits; drop it.
rm -f .config.m3-busybox_qemu-x86_64 .unikraft/build/config
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt --log-type basic
