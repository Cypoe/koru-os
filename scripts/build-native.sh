#!/usr/bin/env bash
# build-native.sh <prog.k> [out.elf] — emit the program via koruc, then link
# a multiboot2 ELF for the koru-native arm: boot.zig (multiboot2 header +
# 32->64 trampoline + kmain) + runtime.zig (heap/console/clock providers) +
# the emitted program. The image is flat, position-fixed at 1 MiB, bootable
# by QEMU -kernel or a GRUB multiboot2 entry.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KORUC="${KORUC:-/w/src/koru/zig-out/bin/koruc.exe}"
ZIG="${ZIG:-/w/tools/zig-0.15.1/zig.exe}"
export PATH="/w/tools/zig-0.15.1:$PATH"

PROG="$(cygpath -m "$1" 2>/dev/null || echo "$1")"
OUT="${2:-kernel.elf}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$PROG" "$WORK/program.k"
# koruc may fail at the final host link (device externs only exist in the
# freestanding image) — the artifact we need is output_emitted.zig.
(cd "$WORK" && "$KORUC" program.k > koruc.out 2>&1) || true
[ -s "$WORK/output_emitted.zig" ] || {
    echo "build-native: koruc did not emit output_emitted.zig"; tail -10 "$WORK/koruc.out"; exit 1;
}

"$ZIG" build-exe \
    -target x86_64-freestanding-none -mcpu=x86_64 \
    -O ReleaseSafe \
    -fno-entry -fno-stack-protector -mno-red-zone \
    -T "$ROOT/koru/native/link.ld" \
    --dep program --dep runtime --dep virtio --dep aspace -Mroot="$ROOT/koru/native/boot.zig" \
    --dep compiler_env -Mprogram="$WORK/output_emitted.zig" \
    -Mcompiler_env="$ROOT/koru/native/compiler_env.zig" \
    -Mruntime="$ROOT/koru/native/runtime.zig" \
    -Mvirtio="$ROOT/koru/native/virtio.zig" \
    -Maspace="$ROOT/koru/native/aspace.zig" \
    -femit-bin="$OUT" || {
    echo "build-native: zig link failed"; exit 1;
}
echo "build-native: $OUT written — boot with: qemu-system-x86_64 -kernel $OUT -serial stdio -display none"
