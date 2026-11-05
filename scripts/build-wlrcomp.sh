#!/bin/bash
# build-wlrcomp.sh <out.elf> — compile the wlroots nested compositor:
# vendored libwayland-server/client + vendored wlroots 0.16.2 (wayland
# + headless backends, pixman renderer, shm allocator) + pixman +
# libxkbcommon + libdrm headers + the arm-truth compat layer, all
# musl-static via zig cc. No meson — the file list is curated here and
# mirrors meson's feature-gated set exactly.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIGBIN="${ZIGBIN:-/w/src/koru-aaa6457/zig-out/bin/zig.exe}"
[ -x "$ZIGBIN" ] || ZIGBIN=/w/tools/zig-0.15.1/zig.exe
WL="$ROOT/koruos/hosted/wayland"
WLR="$ROOT/koruos/hosted/wlroots"
PIX="$ROOT/koruos/hosted/pixman"
XKB="$ROOT/koruos/hosted/xkbcommon"
DRM="$ROOT/koruos/hosted/libdrm"
OUT="${1:-/tmp/wlrcomp.elf}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# zig cc drops .o files in cwd — compile inside WORK so callers' trees
# stay clean (the gate invokes this mid-chain from the repo root).
cd "$WORK"

CC="$ZIGBIN cc -target x86_64-linux-musl -O2 -fno-sanitize=undefined"
CFLAGS="-static -Wno-unused-command-line-argument"

# 1) wayland server+client+shared — both halves in ONE binary here
# (nested compositor: server for /wayland-2, client for /wayland-1).
# wayland-client-protocol.c is byte-identical to wayland-protocol.c —
# linking both is a duplicate-symbol collision, so only the one rides.
# The wlroots glue xdg-shell-protocol.c (v5, era-correct) provides the
# xdg interface symbols; hosted/wayland's v7 copy rides wlserver only.
WL_SRCS="$WL/src/wayland-server.c $WL/src/event-loop.c $WL/src/wayland-shm.c \
$WL/src/connection.c $WL/src/wayland-os.c $WL/src/wayland-util.c \
$WL/src/wayland-client.c $WL/wayland-protocol.c"

# 2) pixman — meson's base TU list; SIMD units are separate TUs with
# their own target flags (pixman-region.c is an include-template, not
# a TU). config.h is ours.
PIX_BASE="pixman.c pixman-access.c pixman-access-accessors.c \
pixman-bits-image.c pixman-combine32.c pixman-combine-float.c \
pixman-conical-gradient.c pixman-filter.c pixman-x86.c \
pixman-edge.c pixman-edge-accessors.c pixman-fast-path.c \
pixman-glyph.c pixman-general.c pixman-gradient-walker.c \
pixman-image.c pixman-implementation.c pixman-linear-gradient.c \
pixman-matrix.c pixman-noop.c pixman-radial-gradient.c \
pixman-region16.c pixman-region32.c pixman-solid-fill.c \
pixman-timer.c pixman-trap.c pixman-utils.c \
pixman-arm.c pixman-ppc.c pixman-mips.c"
PIX_SRCS=""; for f in $PIX_BASE; do PIX_SRCS="$PIX_SRCS $PIX/$f"; done

# 3) xkbcommon — meson's base list (no x11, no registry/util-list).
XKB_SRCS=$(ls "$XKB"/src/*.c "$XKB"/src/compose/*.c "$XKB"/src/xkbcomp/*.c)

# 4) wlroots — every vendored .c (the curated non-backend set) + glue + compat.
WLR_SRCS=$(find "$WLR/src" "$WLR/glue" "$WLR/compat" -name '*.c' ! -name '*.sym')

echo "build-wlrcomp: compiling into $WORK" >&2

# per-dependency include sets — the config.h collision is why these
# stay separate objects instead of one giant cc line.
$CC $CFLAGS -DHAVE_CONFIG_H -I"$WL" -I"$WL/src" -I"$WL/libffi" -c $WL_SRCS 2>"$WORK/wl.err" || { cat "$WORK/wl.err" >&2; exit 1; }
mv ./*.o "$WORK/" 2>/dev/null || true

$CC $CFLAGS -DHAVE_CONFIG_H -I"$PIX" -c $PIX_SRCS 2>"$WORK/pix.err" || { cat "$WORK/pix.err" >&2; exit 1; }
$CC $CFLAGS -DHAVE_CONFIG_H -I"$PIX" -mmmx -c "$PIX/pixman-mmx.c" -o "$WORK/pixman-mmx.o" 2>>"$WORK/pix.err" || { cat "$WORK/pix.err" >&2; exit 1; }
$CC $CFLAGS -DHAVE_CONFIG_H -I"$PIX" -msse2 -c "$PIX/pixman-sse2.c" -o "$WORK/pixman-sse2.o" 2>>"$WORK/pix.err" || { cat "$WORK/pix.err" >&2; exit 1; }
$CC $CFLAGS -DHAVE_CONFIG_H -I"$PIX" -mssse3 -c "$PIX/pixman-ssse3.c" -o "$WORK/pixman-ssse3.o" 2>>"$WORK/pix.err" || { cat "$WORK/pix.err" >&2; exit 1; }
mv ./*.o "$WORK/" 2>/dev/null || true

$CC $CFLAGS -DHAVE_CONFIG_H -I"$XKB/src" -I"$XKB/include" -c $XKB_SRCS 2>"$WORK/xkb.err" || { cat "$WORK/xkb.err" >&2; exit 1; }
mv ./*.o "$WORK/" 2>/dev/null || true

$CC $CFLAGS -DWLR_USE_UNSTABLE -DWLR_LITTLE_ENDIAN=1 -DWLR_BIG_ENDIAN=0 \
  -I"$WLR/src/include" -I"$WLR/glue" -I"$WLR/compat" -I"$DRM" -I"$DRM/drm" \
  -I"$PIX" -I"$XKB/include" -I"$WL" -I"$WL/src" \
  -c $WLR_SRCS 2>"$WORK/wlr.err" || { cat "$WORK/wlr.err" >&2; exit 1; }
mv ./*.o "$WORK/" 2>/dev/null || true

$CC $CFLAGS -DWLR_USE_UNSTABLE -DWLR_LITTLE_ENDIAN=1 -DWLR_BIG_ENDIAN=0 \
  -I"$WLR/src/include" -I"$WLR/glue" -I"$WLR/compat" -I"$DRM" -I"$DRM/drm" \
  -I"$PIX" -I"$XKB/include" -I"$WL" -I"$WL/src" \
  -Wl,--image-base=0x48000000 -Wl,--build-id=none ${WLRCOMP_STRIP:--s} \
  -o "$OUT" "$ROOT/koruos/native/tests/wlrcomp.c" "$WORK"/*.o "$WL/libffi/libffi.a" \
  2>"$WORK/link.err" || { cat "$WORK/link.err" >&2; exit 1; }

echo "build-wlrcomp: $OUT" >&2
