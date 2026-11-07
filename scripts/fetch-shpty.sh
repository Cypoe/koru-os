#!/usr/bin/env bash
# fetch-shpty.sh — fetch alpine dynamic busybox + ld-musl for the
# busybox-sh-pty payload.
#
# Runs inside WSL (check-boot.sh invokes `wsl bash <this> $OUTDIR`);
# writes OUTDIR/bin/busybox + OUTDIR/lib/ld-musl-x86_64.so.1 +
# OUTDIR/lib/libc.musl-x86_64.so.1. Dynamic, not busybox-static: the
# static apk links ET_EXEC at 0x400000 — under USER_VA_BASE — and the
# loader refuses it honestly post-teardown. The dynamic apk is ET_DYN
# and biases above the floor, the same closure the dynamic row stages.
set -euo pipefail
OUT="${1:?usage: fetch-shpty.sh <outdir>}"
ALPINE="https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64"
WORK="$OUT/apk-cache"
mkdir -p "$WORK/x" "$OUT/bin" "$OUT/lib"
cd "$WORK"

IDX="$WORK/APKINDEX"
if [ ! -f "$IDX" ]; then
    curl -sSL "$ALPINE/APKINDEX.tar.gz" | tar xzO APKINDEX > "$IDX"
fi

fetch() { # fetch <apk> — resolve version from the index, cache, extract
    local p="$1" v
    v="$(grep -A4 "^P:$p\$" "$IDX" | grep -m1 "^V:" | cut -d: -f2)"
    [ -n "$v" ] || { echo "fetch-shpty: no $p in index" >&2; return 1; }
    [ -f "$p-$v.apk" ] || curl -sSL "$ALPINE/$p-$v.apk" -o "$p-$v.apk" || return 1
    tar xzf "$p-$v.apk" -C x 2>/dev/null || true
}

for p in musl busybox; do
    fetch "$p"
done

cp x/bin/busybox "$OUT/bin/busybox"
# ld-musl serves two names: the PT_INTERP path AND musl's libc (the
# DT_NEEDED busybox actually links).
cp x/lib/ld-musl-x86_64.so.1 "$OUT/lib/ld-musl-x86_64.so.1"
cp x/lib/ld-musl-x86_64.so.1 "$OUT/lib/libc.musl-x86_64.so.1"
chmod 755 "$OUT/bin/busybox" "$OUT/lib/"*.so.1
echo "fetch-shpty: busybox + ld-musl -> $OUT"
