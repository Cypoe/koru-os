#!/usr/bin/env bash
# build-hosted.sh <prog.k> [out] — emit the program via koruc, then link a
# STATIC linux binary for the hosted/linux arm: output_emitted.zig +
# koru/hosted/linux.zig (the provider shim) + the compiler_env stub.
# Target is x86_64-linux-musl so the artifact runs on any linux
# (WSL, VM, real box) with no runtime deps — same "no host assumptions"
# stance as the freestanding image.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Pinned: see build-native.sh — koru@aaa64576c worktree while ccomp's
# zig emitter leaks |c bodies into zig output.
KORUC="${KORUC:-/w/src/koru-aaa6457/zig-out/bin/koruc.exe}"
ZIG="${ZIG:-/w/tools/zig-0.15.1/zig.exe}"
export PATH="/w/tools/zig-0.15.1:$PATH"

PROG="$(cygpath -m "$1" 2>/dev/null || echo "$1")"
OUT="${2:-hosted.out}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cp "$PROG" "$WORK/program.k"
# koruc may fail at the final host link (provider externs only exist in
# the shim) — the artifact we need is output_emitted.zig.
(cd "$WORK" && "$KORUC" program.k > koruc.out 2>&1) || true
[ -s "$WORK/output_emitted.zig" ] || {
    echo "build-hosted: koruc did not emit output_emitted.zig"; tail -10 "$WORK/koruc.out"; exit 1;
}

# the provider shim as a linkable object — the emitted program's externs
# resolve against it by symbol name.
"$ZIG" build-obj \
    -target x86_64-linux-musl -mcpu=x86_64 \
    -O ReleaseSafe -lc \
    -femit-bin="$WORK/hosted_linux.o" \
    "$ROOT/koru/hosted/linux.zig" || { echo "build-hosted: shim compile failed"; exit 1; }

"$ZIG" build-exe \
    -target x86_64-linux-musl -mcpu=x86_64 \
    -O ReleaseSafe -lc -static \
    --dep compiler_env -Mroot="$WORK/output_emitted.zig" \
    -Mcompiler_env="$ROOT/koru/native/compiler_env.zig" \
    "$WORK/hosted_linux.o" \
    -femit-bin="$OUT" || {
    echo "build-hosted: zig link failed"; exit 1;
}
echo "build-hosted: $OUT written — run under linux: KORU_BLK0=<img> ./$OUT"
