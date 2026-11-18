#!/bin/bash
# build-wlrcomp.sh <out.elf> — compile the wlroots nested compositor:
# vendored libwayland-server/client + vendored wlroots 0.16.2 (wayland
# + headless backends, pixman renderer, shm allocator) + pixman +
# libxkbcommon + libdrm headers + the arm-truth compat layer, all
# musl-static via zig cc. No meson — the file list is curated in
# scripts/wlr-deps.sh and mirrors meson's feature-gated set exactly.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/wlr-deps.sh"
OUT="${1:-/tmp/wlrcomp.elf}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "build-wlrcomp: compiling into $WORK" >&2
wlr_deps_compile "$WORK"

$WLR_CC $WLR_CFLAGS $WLR_APP_DEFS $WLR_APP_INCS \
  -Wl,--image-base=0x48000000 -Wl,--build-id=none ${WLRCOMP_STRIP:--s} \
  -o "$OUT" "$ROOT/koruos/native/tests/wlrcomp.c" "$WORK"/*.o "$WL/libffi/libffi.a" \
  2>"$WORK/link.err" || { cat "$WORK/link.err" >&2; exit 1; }

echo "build-wlrcomp: $OUT" >&2
