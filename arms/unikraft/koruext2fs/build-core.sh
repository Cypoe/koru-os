#!/usr/bin/env bash
# Build ext2core.zig as a freestanding archive for the unikernel.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); mkdir -p "$HERE/build"
export PATH=/workspace/tc/zig-x86_64-linux-0.15.2:$PATH
zig build-lib "$HERE/ext2core.zig" -target x86_64-freestanding -O ReleaseSafe \
  -fno-stack-protector -mno-red-zone -fno-stack-check -femit-bin="$HERE/build/libext2core.a"
ls -la "$HERE/build/libext2core.a"
