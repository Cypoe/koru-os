#!/usr/bin/env bash
# One Spawn run in QEMU (TCG only). Usage: run-nid.sh <kernel> <outdir>
set -u
K=$1; OUT=$2; mkdir -p "$OUT"
t0=$(date +%s.%N)
timeout 60 qemu-system-x86_64 -accel tcg -kernel "$K" \
  -cpu 'qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm' \
  -m 32M -nographic -no-reboot -display none -parallel none > "$OUT/serial.raw" 2>&1
rc=$?; t1=$(date +%s.%N)
tr -d "\r" < "$OUT/serial.raw" | sed "s/^Booting from ROM\.\.//" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1bc//g' > "$OUT/serial.log"
{ echo "qemu exit=$rc wall_s=$(python3 -c "print(round($t1-$t0,3))") accel=tcg"; sha256sum "$K"; } > "$OUT/run.txt"
