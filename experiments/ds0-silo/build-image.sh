#!/usr/bin/env bash
# Build the DS0 unikernel: koruos/silo + boot_silo.k inside a Koru-built Unikraft image.
# Usage: build-image.sh <koru-libs checkout @ ff5cb559> <workdir>
set -euo pipefail
LIBS=$1; W=$2; REPO=$(cd "$(dirname "$0")/../.." && pwd)
rm -rf "$W"; mkdir -p "$W/koruos"
cp -R "$REPO/koru/silo" "$W/koruos/"; cp -R "$LIBS/unikraft" "$W/"
cd "$W/koruos/silo/tests"
koruc boot_silo.k unikraft gen
koruc boot_silo.k
zig build-lib wrapper.zig -target x86_64-freestanding -O ReleaseSmall -fno-stack-protector -femit-bin=libkoruapp.a
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt --log-type basic
ls -la .unikraft/build/koru_qemu-x86_64 libkoruapp.a
