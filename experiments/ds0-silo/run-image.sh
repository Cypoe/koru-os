#!/usr/bin/env bash
# DS0 acceptance in QEMU (TCG only): boot the image, compare serial lines with expected.txt.
# Usage: run-image.sh <kernel> <outdir>
set -u
K=$1; OUT=$2; HERE=$(cd "$(dirname "$0")" && pwd); mkdir -p "$OUT"
t0=$(date +%s.%N)
timeout 60 qemu-system-x86_64 -accel tcg -kernel "$K" \
  -cpu 'qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm' \
  -m 32M -nographic -no-reboot -display none -parallel none > "$OUT/serial.raw" 2>&1
rc=$?; t1=$(date +%s.%N)
tr -d "\r" < "$OUT/serial.raw" | sed "s/^Booting from ROM\.\.//" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1bc//g' > "$OUT/serial.log"
grep -E '^(refused|revoked|dispatched|empty0|blk0|DS0|FAIL)' "$OUT/serial.log" > "$OUT/got.txt"
{ echo "qemu exit=$rc wall_s=$(python3 -c "print(round($t1-$t0,3))") accel=tcg"
  sha256sum "$K"
  if diff -u "$HERE/expected.txt" "$OUT/got.txt"; then echo "DS0-image PASS"; else echo "DS0-image FAIL"; fi
} > "$OUT/run.txt"; cat "$OUT/run.txt"
