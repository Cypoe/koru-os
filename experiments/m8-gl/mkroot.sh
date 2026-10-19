#!/usr/bin/env bash
# Builds the M8 guest/L1 userland tree <dst>: gloff + glvnd EGL/GLES (from <m8in root>) +
# Mesa EGL/gallium/LLVM, the GBM dri backend, kms_swrast (dril) and their dependencies (from the box's Debian 13 /usr/lib), glibc.
# With a third argument (an extracted kmscube + gstreamer-plugins-base root) also kmscube.
# Usage: mkroot.sh <m8in root> <dst> [kmscube root]
set -eu
IN=$1; D=$2; KR=${3:-}; HERE=$(cd "$(dirname "$0")" && pwd); L=$D/lib/x86_64-linux-gnu
mkdir -p "$D"/{bin,lib64,usr/share/glvnd/egl_vendor.d} "$L"
gcc -O2 -Wall -I"$IN/usr/include" -o "$D/bin/gloff" "$HERE/gloff.c" -L"$IN/usr/lib/x86_64-linux-gnu" -lEGL -lGLESv2 -lgbm
cp -L /lib64/ld-linux-x86-64.so.2 "$D/lib64/"
cp "$IN/usr/share/glvnd/egl_vendor.d/50_mesa.json" "$D/usr/share/glvnd/egl_vendor.d/"
G=/usr/lib/x86_64-linux-gnu; export LD_LIBRARY_PATH=$IN/usr/lib/x86_64-linux-gnu
U=$D/usr/lib/x86_64-linux-gnu; mkdir -p "$U/gbm" "$U/dri"   # Mesa searches these compiled-in paths
cp $G/gbm/dri_gbm.so "$U/gbm/"; cp $G/dri/libdril_dri.so "$U/dri/"; ln -sf libdril_dri.so "$U/dri/kms_swrast_dri.so"
[ -n "$KR" ] && { mkdir -p "$D/usr/bin"; cp "$KR/usr/bin/kmscube" "$D/usr/bin/"; export LD_LIBRARY_PATH=$KR/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH; }
for o in "$D/bin/gloff" ${KR:+"$D/usr/bin/kmscube"} "$IN/usr/lib/x86_64-linux-gnu/libEGL_mesa.so.0" $G/libgallium-*.so $G/gbm/dri_gbm.so $G/dri/libdril_dri.so; do ldd "$o" | awk '$3 ~ /^\// {print $3}'; done | sort -u > "$D/.libs"
for l in $(cat "$D/.libs") "$IN/usr/lib/x86_64-linux-gnu/libEGL_mesa.so.0" $G/libgallium-*.so; do cp -L "$l" "$L/"; done
rm "$D/.libs"
