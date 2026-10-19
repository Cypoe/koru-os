#!/usr/bin/env bash
# Build the dissected Spawn skeleton image: koruos/spawn + boot_spawn.k, kconfig derived by koruos/realize.
# Usage: build-spawn.sh <koru-libs @ ff5cb559> <workdir>
set -euo pipefail
LIBS=$1; W=$2; REPO=$(cd "$(dirname "$0")/../.." && pwd)
rm -rf "$W"; mkdir -p "$W/koruos"
cp -R "$REPO/koru/spawn" "$REPO/koru/realize" "$W/koruos/"; cp -R "$LIBS/unikraft" "$W/"
cd "$W/koruos/spawn/tests"
koruc boot_spawn.k realize gen
koruc boot_spawn.k > koruc-emit.log 2>&1 || true
if grep -q error koruc-emit.log && ! grep -q "undefined symbol: ukplat_monotonic_clock" koruc-emit.log; then cat koruc-emit.log; exit 1; fi
test -s output_emitted.zig
zig build-lib wrapper.zig -target x86_64-freestanding -O ReleaseSmall -fno-stack-protector -femit-bin=libkoruapp.a
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt --log-type basic
ls -la .unikraft/build/koru_qemu-x86_64
