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

# keep the source extension — `.k` is pure-Koru, `.kz` host-embeds zig
EXT="${PROG##*.}"
cp "$PROG" "$WORK/program.$EXT"
# koruc may fail at the final host link (provider externs only exist in
# the shim) — the artifact we need is output_emitted.zig.
(cd "$WORK" && "$KORUC" "program.$EXT" > koruc.out 2>&1) || true
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

# Interpreter programs (std/interpreter) emit references to the koru
# compiler's own zig modules (ast, koru_parser, flow_parser, liquid and
# their closure). Mirror the dep graph koruc's generated build_output.zig
# produces — same edges, same module files — so a REPL/shell program links
# here exactly as it does for `koruc run`.
KORU_SRC="${KORU_SRC:-$(cd "$(dirname "$KORUC")/../.." && pwd)/src}"
if [ ! -f "$KORU_SRC/parser.zig" ]; then
    echo "build-hosted: KORU_SRC=$KORU_SRC has no parser.zig (set KORU_SRC to the compiler's src/)"; exit 1;
fi
INTERP_DEPS=(
    --dep errors --dep glob_pattern_matcher
        -Mast="$KORU_SRC/ast.zig"
    --dep ast --dep lexer
        -Mexpression_parser="$KORU_SRC/expression_parser.zig"
    --dep ast --dep expression_parser
        -Mcomptime_eval="$KORU_SRC/comptime_eval.zig"
    --dep ast --dep log
        -Mtype_registry="$KORU_SRC/type_registry.zig"
    --dep log
        -Mconfig="$KORU_SRC/config.zig"
    --dep config --dep log --dep file_types
        -Mmodule_resolver="$KORU_SRC/module_resolver.zig"
    --dep ast
        -Mast_mangle="$KORU_SRC/ast_mangle.zig"
    --dep ast
        -Munion_collector="$KORU_SRC/union_collector.zig"
    --dep liquid
        -Mstruct_literal="$KORU_SRC/struct_literal.zig"
    --dep struct_literal --dep ast --dep ast_mangle --dep lexer --dep errors
    --dep type_registry --dep expression_parser --dep comptime_eval
    --dep annotation_parser --dep union_collector --dep module_resolver
    --dep file_types
        -Mkoru_parser="$KORU_SRC/parser.zig"
    --dep ast --dep lexer --dep errors --dep expression_parser
        -Mflow_parser="$KORU_SRC/flow_parser.zig"
    -Merrors="$KORU_SRC/errors.zig"
    -Mglob_pattern_matcher="$KORU_SRC/glob_pattern_matcher.zig"
    -Mlog="$KORU_SRC/log.zig"
    -Mlexer="$KORU_SRC/lexer.zig"
    -Mliquid="$KORU_SRC/liquid.zig"
    -Mfile_types="$KORU_SRC/file_types.zig"
    -Mannotation_parser="$KORU_SRC/annotation_parser.zig"
)

"$ZIG" build-exe \
    -target x86_64-linux-musl -mcpu=x86_64 \
    -O ReleaseSafe -lc -static \
    --dep compiler_env --dep ast --dep koru_parser --dep koru_errors=errors --dep flow_parser --dep liquid \
    -Mroot="$WORK/output_emitted.zig" \
    -Mcompiler_env="$ROOT/koru/native/compiler_env.zig" \
    "${INTERP_DEPS[@]}" \
    "$WORK/hosted_linux.o" \
    -femit-bin="$OUT" || {
    echo "build-hosted: zig link failed"; exit 1;
}
echo "build-hosted: $OUT written — run under linux: KORU_BLK0=<img> ./$OUT"
