#!/usr/bin/env bash
set -u
K=${1:-/workspace/spelf/.unikraft/build/spawn-elf_qemu-x86_64}
OUT=${2:-/tmp/spelf-run}
mkdir -p "$OUT"
t0=$(date +%s.%N)
timeout 90 qemu-system-x86_64 -accel tcg \
  -cpu 'qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm' \
  -m 128M -nographic -no-reboot -display none -parallel none \
  -kernel "$K" > "$OUT/serial.raw" 2>&1
rc=$?; t1=$(date +%s.%N)
tr -d '\r' < "$OUT/serial.raw" | sed "s/^Booting from ROM\.\.//" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1bc//g' > "$OUT/serial.log"
{ echo "qemu exit=$rc wall_s=$(python3 -c "print(round($t1-$t0,3))") accel=tcg"; sha256sum "$K"; } > "$OUT/run.txt"
