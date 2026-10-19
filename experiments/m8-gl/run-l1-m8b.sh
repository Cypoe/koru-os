#!/usr/bin/env bash
# M8b L1 oracle run (TCG, same -cpu as run-m8b.sh): Debian 6.12.113 + bochs-drm, the run-m8b.sh
# userland (mkroot.sh with kmscube), same shots.py screendumps, strace -f -c. Never a pass.
# Usage: run-l1-m8b.sh <linux-image dir> <dir with ko/ + modorder.txt> <busybox> <m8in root> <kmscube root> <outdir>
set -u
KX=$1; KO=$2; BB=$3; IN=$4; KR=$5; OUT=$6; HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$OUT"; mkdir -p "$OUT"/ir/{bin,dev,proc,sys,tmp,ko}; cd "$OUT"
cp "$BB" ir/bin/busybox; cp "$HERE/l1-init-m8b" ir/init; chmod 755 ir/init
"$HERE/mkroot.sh" "$IN" ir "$KR"
cp /usr/bin/strace ir/bin/strace; ldd /usr/bin/strace | awk '$3 ~ /^\// {print $3}' | while read -r l; do cp -Ln "$l" ir/lib/x86_64-linux-gnu/ 2>/dev/null || true; done
cp "$KO"/ko/*.ko ir/ko/; cp "$KO/modorder.txt" ir/
python3 "$HERE/mkcpio.py" ir | gzip -1 > initrd.gz
rm -f qmp.sock serial.raw; t0=$(date +%s.%N)
timeout 900 qemu-system-x86_64 -accel tcg -cpu qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm -m 2G -display none -vga none -device bochs-display \
  -no-reboot -parallel none -serial file:serial.raw -qmp unix:qmp.sock,server,nowait \
  -kernel "$KX"/boot/vmlinuz-* -initrd initrd.gz -append "console=ttyS0 quiet panic=-1" > qemu-stdout.txt 2>&1 &
qp=$!
python3 "$HERE/shots.py" "$OUT" "$qp" 890
wait $qp; echo "qemu exit=$? wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))")" > result.txt
tr -d '\r' < serial.raw > serial.log
rm -rf ir initrd.gz; cat result.txt
