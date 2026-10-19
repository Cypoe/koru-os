#!/usr/bin/env bash
# M5a inputs (nothing here is committed): a dynamically linked glibc-PIE busybox 1.37.0 (same
# config as M3, without -static-pie) and hello.c linked against musl and against glibc.
# Needs musl-tools (Debian musl 1.2.5) on the build host. Usage: build-inputs.sh <outdir>
set -euo pipefail
OUT=$1; HERE=$(cd "$(dirname "$0")" && pwd); M3=$HERE/../m3-busybox
mkdir -p "$OUT" && cd "$OUT"
[ -f busybox-1.37.0.tar.bz2 ] || curl -sSfLO https://busybox.net/downloads/busybox-1.37.0.tar.bz2
echo "3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4  busybox-1.37.0.tar.bz2" | sha256sum -c -
rm -rf busybox-1.37.0 && tar xjf busybox-1.37.0.tar.bz2 && cd busybox-1.37.0
cp "$M3/busybox.config" .config
set +o pipefail; yes "" | make oldconfig >/dev/null; set -o pipefail
make -j"$(nproc)" busybox CFLAGS_busybox="-pie" > build.log 2>&1
cp busybox "$OUT/busybox-dyn" && cd "$OUT"
musl-gcc -O1 -fPIE -pie -o hello-musl "$HERE/hello.c"
gcc -O1 -fPIE -pie -o hello-glibc "$HERE/hello.c"
file busybox-dyn hello-musl hello-glibc | sed 's/BuildID[^,]*, //'
sha256sum busybox-dyn hello-musl hello-glibc
