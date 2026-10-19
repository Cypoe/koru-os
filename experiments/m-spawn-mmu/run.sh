#!/usr/bin/env bash
# run.sh <kernel> <outdir>   (TCG only)
set -euo pipefail
K=$1; OUT=$2
mkdir -p "$OUT"
t0=$(date +%s.%N)
timeout 30 qemu-system-x86_64 -accel tcg \
  -cpu 'qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm' \
  -m 128M -nographic -no-reboot -display none -parallel none \
  -kernel "$K" > "$OUT/serial.raw" 2>&1 || true
t1=$(date +%s.%N)
# strip ANSI / uk_pr noise to serial.log text
tr -cd '\11\12\15\40-\176' < "$OUT/serial.raw" > "$OUT/serial.log" || cp "$OUT/serial.raw" "$OUT/serial.log"
echo "qemu wall_s=$(python3 -c "print(round($t1-$t0,3))") accel=tcg" > "$OUT/run.txt"
sha256sum "$K" >> "$OUT/run.txt"
