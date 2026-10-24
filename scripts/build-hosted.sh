#!/usr/bin/env bash
# build-hosted.sh <prog.k> [out] [shim] — emit the program via koruc, then
# link a hosted-arm binary: output_emitted.zig + koru/hosted/<shim>.zig
# (the provider shim) + the compiler_env stub.
#
#   shim=linux     → x86_64-linux-musl -static (runs on any linux: WSL,
#                    VM, real box — no runtime deps)
#   shim=linux-x11 → x86_64-linux-gnu dynamic — same provider surface plus
#                    koru/hosted/x11.zig (koruos.surface over libX11.so.6,
#                    read via the WSL UNC mount). Runs where a display is.
#   shim=linux-wayland → x86_64-linux-gnu dynamic — provider surface +
#                    koru/hosted/wayland.zig: koruos.surface+input over
#                    libwayland-client (wl_shm + xdg_shell; vendored
#                    generated bindings in koru/hosted/wayland/). The
#                    protocol hyprland speaks — runs where a wayland
#                    compositor is (WSLg today).
#   shim=freebsd   → x86_64-freebsd -lc (dynamic; the Capsicum spawn arm —
#                    build-check on this host, runs on a real FreeBSD)
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Pinned: see build-native.sh — koru@aaa64576c worktree while ccomp's
# zig emitter leaks |c bodies into zig output.
KORUC="${KORUC:-/w/src/koru-aaa6457/zig-out/bin/koruc.exe}"
ZIG="${ZIG:-/w/tools/zig-0.15.1/zig.exe}"
export PATH="/w/tools/zig-0.15.1:$PATH"

PROG="$(cygpath -m "$1" 2>/dev/null || echo "$1")"
OUT="${2:-hosted.out}"
SHIM="${3:-linux}"
LINKS=()

case "$SHIM" in
    linux)
        # static musl — runs on any linux, zero runtime deps. No display.
        TARGS=(-target x86_64-linux-musl -mcpu=x86_64 -static)
        SHIM_SRCS=("$ROOT/koru/hosted/linux.zig") ;;
    linux-x11)
        # glibc-dynamic — the display-capable arm: linux.zig's provider
        # surface + x11.zig's koruos.surface over libX11 (WSLg). The lib is
        # read through the WSL UNC mount — Windows zig links the .so by
        # path; no dev package is needed on the linux side.
        TARGS=(-target x86_64-linux-gnu -mcpu=x86_64)
        SHIM_SRCS=("$ROOT/koru/hosted/linux.zig" "$ROOT/koru/hosted/x11.zig")
        LINKS=(X11_SO) ;;
    linux-wayland)
        # musl-static like shim=linux — libwayland-client 1.26.0 is
        # vendored as *source* (koru/hosted/wayland/src/, MIT) and
        # compiled into the binary: zero runtime deps, runs on the host
        # AND inside the vroot unchanged. Static is also the honest arm:
        # the host's libwayland (1.18) predates wl_proxy_marshal_flags.
        TARGS=(-target x86_64-linux-musl -mcpu=x86_64 -static)
        SHIM_SRCS=("$ROOT/koru/hosted/linux.zig" "$ROOT/koru/hosted/wayland.zig")
        CSRCS=("$ROOT/koru/hosted/wayland/wayland-client-protocol.c"
               "$ROOT/koru/hosted/wayland/xdg-shell-protocol.c"
               "$ROOT/koru/hosted/wayland/src/wayland-client.c"
               "$ROOT/koru/hosted/wayland/src/connection.c"
               "$ROOT/koru/hosted/wayland/src/wayland-os.c"
               "$ROOT/koru/hosted/wayland/src/wayland-util.c")
        # libffi is wayland's only external dep (demarshal closures) —
        # vendored musl .a + headers from alpine's libffi-dev.
        LINKS=("$ROOT/koru/hosted/wayland/libffi/libffi.a") ;;
    freebsd)
        TARGS=(-target x86_64-freebsd -mcpu=x86_64)
        SHIM_SRCS=("$ROOT/koru/hosted/freebsd.zig") ;;
    *)
        TARGS=(-target "$SHIM")
        SHIM_SRCS=("$ROOT/koru/hosted/$SHIM.zig")
        [ -f "${SHIM_SRCS[0]}" ] || { echo "build-hosted: no shim ${SHIM_SRCS[0]}"; exit 1; } ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# linux-x11: fetch the distro's libX11 into the workdir — zig links a .so
# by path (no dev package needed); the runtime resolves the same SONAME.
if [ "${LINKS[0]:-}" = "X11_SO" ]; then
    WORKWSL="$(MSYS2_ARG_CONV_EXCL='*' wsl -d "${WSL_DISTRO:-Ubuntu}" -e wslpath -u "$(cygpath -w "$WORK")")" || {
        echo "build-hosted: wslpath failed (is WSL distro ${WSL_DISTRO:-Ubuntu} up?)"; exit 1; }
    MSYS2_ARG_CONV_EXCL='*' wsl -d "${WSL_DISTRO:-Ubuntu}" -e cp \
        /usr/lib/x86_64-linux-gnu/libX11.so.6 "$WORKWSL/libX11.so.6" || {
        echo "build-hosted: no libX11.so.6 in ${WSL_DISTRO:-Ubuntu}"; exit 1; }
    LINKS=("$WORK/libX11.so.6")
fi



# keep the source extension — `.k` is pure-Koru, `.kz` host-embeds zig
EXT="${PROG##*.}"
cp "$PROG" "$WORK/program.$EXT"
# koruc may fail at the final host link (provider externs only exist in
# the shim) — the artifact we need is output_emitted.zig.
(cd "$WORK" && "$KORUC" "program.$EXT" > koruc.out 2>&1) || true
[ -s "$WORK/output_emitted.zig" ] || {
    echo "build-hosted: koruc did not emit output_emitted.zig"; tail -10 "$WORK/koruc.out"; exit 1;
}

# the provider shim(s) as linkable objects — the emitted program's
# externs resolve against them by symbol name.
SHIM_OBJS=()
i=0
for src in "${SHIM_SRCS[@]}"; do
    i=$((i+1))
    "$ZIG" build-obj \
        "${TARGS[@]}" \
        -O ReleaseSafe -lc \
        -I "$ROOT/koru/hosted/wayland" -I "$ROOT/koru/hosted/wayland/src" \
        -I "$ROOT/koru/hosted/wayland/libffi" \
        -femit-bin="$WORK/hosted_shim_$i.o" \
        "$src" || { echo "build-hosted: shim compile failed ($src)"; exit 1; }
    SHIM_OBJS+=("$WORK/hosted_shim_$i.o")
done
# vendored C glue (generated protocol tables + libwayland-client src) —
# C objects via zig cc
for csrc in ${CSRCS[@]+"${CSRCS[@]}"}; do
    i=$((i+1))
    "$ZIG" build-obj \
        "${TARGS[@]}" \
        -O ReleaseSafe -lc \
        -I "$ROOT/koru/hosted/wayland" -I "$ROOT/koru/hosted/wayland/src" \
        -I "$ROOT/koru/hosted/wayland/libffi" \
        -femit-bin="$WORK/hosted_c_$i.o" \
        "$csrc" || { echo "build-hosted: C glue compile failed ($csrc)"; exit 1; }
    SHIM_OBJS+=("$WORK/hosted_c_$i.o")
done

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
    "${TARGS[@]}" \
    -O ReleaseSafe -lc \
    --dep compiler_env --dep ast --dep koru_parser --dep koru_errors=errors --dep flow_parser --dep liquid \
    -Mroot="$WORK/output_emitted.zig" \
    -Mcompiler_env="$ROOT/koru/native/compiler_env.zig" \
    "${INTERP_DEPS[@]}" \
    "${SHIM_OBJS[@]}" \
    "${LINKS[@]}" \
    -femit-bin="$OUT" || {
    echo "build-hosted: zig link failed"; exit 1;
}
echo "build-hosted: $OUT written — shim=$SHIM"
