#!/usr/bin/env bash
# build-native.sh <prog.k> [out.elf] — emit the program via koruc, then link
# a multiboot2 ELF for the koru-native arm: boot.zig (multiboot2 header +
# 32->64 trampoline + kmain) + runtime.zig (heap/console/clock providers) +
# the emitted program. The image is flat, position-fixed at 1 MiB, bootable
# by QEMU -kernel or a GRUB multiboot2 entry.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Pinned: koru@aaa64576c worktree — the live /w/src/koru checkout is on
# fork/ccomp where the zig emitter leaks |c proc bodies into zig output
# (handler__c with raw C text — every std/io consumer fails the backend
# build). Restore to /w/src/koru/zig-out/bin/koruc.exe once fixed.
KORUC="${KORUC:-/w/src/koru-aaa6457/zig-out/bin/koruc.exe}"
ZIG="${ZIG:-/w/tools/zig-0.15.1/zig.exe}"
export PATH="/w/tools/zig-0.15.1:$PATH"

PROG="$(cygpath -m "$1" 2>/dev/null || echo "$1")"
OUT="${2:-kernel.elf}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# keep the source extension — `.k` is pure-Koru, `.kz` host-embeds zig
EXT="${PROG##*.}"
cp "$PROG" "$WORK/program.$EXT"
# koruc may fail at the final host link (device externs only exist in the
# freestanding image) — the artifact we need is output_emitted.zig.
(cd "$WORK" && "$KORUC" "program.$EXT" > koruc.out 2>&1) || true
[ -s "$WORK/output_emitted.zig" ] || {
    echo "build-native: koruc did not emit output_emitted.zig"; tail -10 "$WORK/koruc.out"; exit 1;
}

"$ZIG" build-exe \
    -target x86_64-freestanding-none -mcpu=x86_64 \
    -O ReleaseSafe \
    -fno-entry -fno-stack-protector -mno-red-zone \
    -T "$ROOT/koru/native/link.ld" \
    --dep program --dep runtime --dep virtio --dep aspace --dep user --dep pmm --dep kbd -Mroot="$ROOT/koru/native/boot.zig" \
    --dep compiler_env -Mprogram="$WORK/output_emitted.zig" \
    -Mcompiler_env="$ROOT/koru/native/compiler_env.zig" \
    -Mruntime="$ROOT/koru/native/runtime.zig" \
    -Mvirtio="$ROOT/koru/native/virtio.zig" \
    --dep pmm -Maspace="$ROOT/koru/native/aspace.zig" \
    --dep pmm --dep kbd -Muser="$ROOT/koru/native/user.zig" \
    -Mpmm="$ROOT/koru/native/pmm.zig" \
    -Mkbd="$ROOT/koru/native/kbd.zig" \
    -femit-bin="$OUT" || {
    echo "build-native: zig link failed"; exit 1;
}
echo "build-native: $OUT written — boot with: qemu-system-x86_64 -kernel $OUT -serial stdio -display none"
