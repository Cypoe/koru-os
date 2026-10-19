#!/usr/bin/env bash
# Build the static-pie hello child with zig (musl). No GPL binary is committed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-"$HERE/rootfs/bin/hello"}
export PATH=/workspace/tc/zig-x86_64-linux-0.15.2:$PATH
mkdir -p "$(dirname "$OUT")"
zig cc -target x86_64-linux-musl -fPIE -static-pie -O2 -o "$OUT" "$HERE/child/hello.c"
file "$OUT"
ls -la "$OUT"
