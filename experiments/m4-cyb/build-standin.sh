#!/usr/bin/env bash
# Build the T-CYB STAND-IN /bin/ascii-animator and its /assets/80x24.anim.
# Inputs come from a local checkout of Cypoe/plex-shell (private, pinned f34e473f, see
# notes/plex-shell-crates.md). anim.rs and boot.anim are NOT committed here; they are
# copied at build time and checked against the sha256 pins below.
# Usage: build-standin.sh <plex-shell checkout> <outdir>
set -eu
PS=$1; OUT=$2; HERE=$(cd "$(dirname "$0")" && pwd)
ANIM_RS_SHA=9b671ec247c7500b16482888227b66bb270ac068894fc925fe9680639d107c14
BOOT_ANIM_SHA=b7de296456cffe479170c15b77077627c566170b03adcff2a5d1c5c40f3f3ae5
echo "$ANIM_RS_SHA  $PS/crates/plex-libs/src/anim.rs" | sha256sum -c -
echo "$BOOT_ANIM_SHA  $PS/crates/plex-os/assets/boot.anim" | sha256sum -c -
mkdir -p "$OUT"
cp "$PS/crates/plex-libs/src/anim.rs" "$HERE/standin/src/anim.rs"
(cd "$HERE/standin" && cargo build --release --target x86_64-unknown-linux-musl --target-dir "$OUT/target" -q)
cp "$OUT/target/x86_64-unknown-linux-musl/release/ascii-animator" "$OUT/ascii-animator"
python3 "$HERE/recut.py" "$PS/crates/plex-os/assets/boot.anim" "$OUT/80x24.anim" "$OUT/frames.json"
file "$OUT/ascii-animator"
sha256sum "$OUT/ascii-animator" "$OUT/80x24.anim"
