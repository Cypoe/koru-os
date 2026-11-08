#!/bin/bash
# fetch-kroot.sh — assemble the klanker-on-CPython payload for the
# klanker-child probe (koruos/native/tests/kroot.cpio).
#
# Runs fetch-pyroot.sh first (it owns the Alpine/apk staging + the
# trimmed stdlib), then overlays site-packages with the project-owned
# agents-* sources and klanker itself — same-kernel deps, no wheels —
# plus /run (the socket-bind dir) and /main.py = the klanker probe.
#
# usage: fetch-kroot.sh [OUT.cpio]   (default: tests/kroot.cpio)
# Runs inside WSL.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/koruos/native/tests/kroot.cpio}"
STAGE=/home/$USER/pystage-koru

bash "$ROOT/scripts/fetch-pyroot.sh" "$ROOT/koruos/native/tests/pyroot.cpio"

REPOS=/mnt/c/Users/fabi0/repos
# -S drops site.py's path hook, so "site-packages" would be invisible —
# the packages land flat in the stdlib dir itself, where -S still sees
# them. They are unmodified project sources; only the PLACEMENT differs.
SP="$STAGE/root/usr/lib/python3.12"
mkdir -p "$SP" "$STAGE/root/run"
cp -r "$REPOS/klanker/src/klanker" "$SP/"
find "$SP/klanker" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
for d in agents-relay agents-memory agents-traces agents-docs \
         agents-terminal agents-calendar agents-sync agents-keys \
         agents-browser vand; do
  [ -d "$REPOS/$d/src" ] && cp -r "$REPOS/$d/src/." "$SP/" && true
done
# agents-harness ships `runner/` at repo root, not src/
cp -r "$REPOS/agents-harness/runner" "$SP/" 2>/dev/null || true
find "$SP" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

cp "$ROOT/koruos/native/tests/kmain.py" "$STAGE/root/main.py"
# the provider-manifest overlay — AGENTS_PROVIDERS_DIR=/providers in
# the probe; lmstudio.local names LM Studio's llama-server on the
# QEMU host (slirp 10.0.2.2) with literal url+model, auth disabled.
mkdir -p "$STAGE/root/providers"
cp "$ROOT/koruos/native/tests/lmstudio.local.json" "$STAGE/root/providers/"

cd "$STAGE/root"
find . -mindepth 1 | LC_ALL=C sort | cpio -o -H newc > "$STAGE/kroot.cpio"
cp "$STAGE/kroot.cpio" "$OUT"
echo "fetch-kroot: $OUT written ($(du -h "$OUT" | cut -f1))"
