#!/usr/bin/env bash
# M9 + Q30 stage 2, 3 counted boots (TCG): [R1STEP=n] scripts/m9s2x3.sh <kernel> <outdir> [timeout]
set -u
K=$(realpath "$1"); O=$(realpath -m "$2"); TMO=${3:-600}
E9=/workspace/koru-os-repo/experiments/m9-hyprland
mkdir -p "$O"; : > "$O/summary.txt"
for i in 1 2 3; do
  "$E9/run-m9.sh" "$K" /workspace/m3/busybox-1.37.0/busybox /workspace/m9t-root "$E9/m9-accept-init" "$O/run-$i" "$TMO" > "$O/run-$i.out" 2>&1
  python3 "$E9/check.py" "$O/run-$i" "$E9/refused-by-design.txt" > "$O/run-$i/check.txt" 2>&1
  python3 "$E9/check-q30-stage2.py" "$O/run-$i" > "$O/run-$i/check-stage2.txt" 2>&1
  R1=""; if [ -n "${R1STEP:-}" ]; then python3 "$E9/check-r1.py" "$O/run-$i" "$R1STEP" > "$O/run-$i/check-r1.txt" 2>&1; R1=" / $(tail -1 "$O/run-$i/check-r1.txt")"; fi
  echo "run-$i $(tail -1 "$O/run-$i/check.txt") / $(tail -1 "$O/run-$i/check-stage2.txt")$R1 / $(sha256sum "$K" | cut -c1-12)" >> "$O/summary.txt"
done
cat "$O/summary.txt"
