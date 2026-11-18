#!/bin/bash
# build-cage.sh <out.elf> — compile UNMODIFIED upstream cage 0.1.5
# (koruos/hosted/cage, MIT — see VENDORED.md) against the same vendored
# stack wlrcomp rides: libwayland both halves + wlroots 0.16.2 + pixman
# + xkbcommon + libdrm headers, musl-static via zig cc. The dep compile
# is shared through scripts/wlr-deps.sh so the two consumers cannot
# drift from the curated source set.
#
# cage_sources mirrors upstream meson's list minus xwayland.c — the
# vendored config.h pins CAGE_HAS_XWAYLAND 0 (no X11 provider on the
# arm; the call sites fold away at compile time).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/wlr-deps.sh"
CAGE="$ROOT/koruos/hosted/cage"
OUT="${1:-/tmp/cage.elf}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CAGE_SRCS="$CAGE/cage.c $CAGE/idle_inhibit_v1.c $CAGE/output.c \
$CAGE/seat.c $CAGE/view.c $CAGE/xdg_shell.c"

echo "build-cage: compiling into $WORK" >&2
wlr_deps_compile "$WORK"

# -DDEBUG mirrors meson's debug buildtype flag: without it cage's
# wlr_log_init floor is WLR_ERROR and the serial carries no evidence.
$WLR_CC $WLR_CFLAGS $WLR_APP_DEFS $WLR_APP_INCS \
  -DDEBUG -I"$CAGE" \
  -Wl,--image-base=0x48000000 -Wl,--build-id=none ${CAGE_STRIP:--s} \
  -o "$OUT" $CAGE_SRCS "$WORK"/*.o "$WL/libffi/libffi.a" \
  2>"$WORK/link.err" || { cat "$WORK/link.err" >&2; exit 1; }

echo "build-cage: $OUT" >&2
