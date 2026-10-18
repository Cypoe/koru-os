#!/usr/bin/env bash
# Build the M2 unikernel (koruos/ext2 + boot_ext2.k). Usage: build-image.sh <koru-libs @ ff5cb559> <workdir>
set -euo pipefail
LIBS=$1; W=$2; REPO=$(cd "$(dirname "$0")/../.." && pwd)
rm -rf "$W"; mkdir -p "$W/koruos"; cp -R "$REPO/koru/ext2" "$W/koruos/"; cp -R "$LIBS/unikraft" "$W/"
cd "$W/koruos/ext2/tests"
koruc boot_ext2.k unikraft gen
koruc boot_ext2.k || true   # host link fails on Unikraft symbols; output_emitted.zig is what we need
test -s output_emitted.zig
zig build-lib wrapper.zig -target x86_64-freestanding -O ReleaseSmall -fno-stack-protector -femit-bin=libkoruapp.a
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt --log-type basic
