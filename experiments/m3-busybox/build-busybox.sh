#!/usr/bin/env bash
# Build static-PIE, NOMMU busybox 1.37.0 for app-elfloader (glibc, gcc -static-pie).
set -euo pipefail
W=${W:-/workspace/m3}; HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$W" && cd "$W"
[ -f busybox-1.37.0.tar.bz2 ] || curl -sSfLO https://busybox.net/downloads/busybox-1.37.0.tar.bz2
echo "3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4  busybox-1.37.0.tar.bz2" | sha256sum -c -
[ -d busybox-1.37.0 ] || tar xjf busybox-1.37.0.tar.bz2
cd busybox-1.37.0
cp "$HERE/busybox.config" .config
yes "" | make oldconfig >/dev/null
# -fPIE comes from CONFIG_EXTRA_CFLAGS; final link only gets -static-pie.
make -j"$(nproc)" busybox CFLAGS_busybox="-static-pie"
file busybox; sha256sum busybox
