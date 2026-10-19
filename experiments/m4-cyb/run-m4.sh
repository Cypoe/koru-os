#!/usr/bin/env bash
# M4 / T-CYB stand-in run (TCG only). Builds an ext2 root with static-PIE busybox, the
# STAND-IN /bin/ascii-animator and /assets/80x24.anim, boots the M3-arm unikernel with
# "/bin/busybox sh /etc/t-cyb-init", takes a mid-run screendump (kept on the box only),
# then runs check.py plus the disk-unchanged and e2fsck checks.
# Usage: run-m4.sh <kernel> <busybox> <standin outdir from build-standin.sh> <outdir>
set -u
K=$1; BB=$2; SI=$3; OUT=$4; S=/usr/sbin; HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$OUT"; mkdir -p "$OUT/root/bin" "$OUT/root/tmp" "$OUT/root/dev" "$OUT/root/etc" "$OUT/root/assets"; cd "$OUT"
cp "$BB" root/bin/busybox
(cd root/bin && for a in $(./busybox --list); do [ "$a" = busybox ] || ln -sf busybox "$a"; done)
cp "$SI/ascii-animator" root/bin/ascii-animator; cp "$SI/80x24.anim" root/assets/80x24.anim
cp "$HERE/t-cyb-init" root/etc/t-cyb-init; chmod 755 root/etc/t-cyb-init root/bin/ascii-animator
$S/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 512 -O none -L koru-root -E root_owner=0:0 -d root disk.img 16384 2>/dev/null
$S/e2fsck -fn disk.img > e2fsck-0.txt 2>&1; echo "mkfs e2fsck exit=$? ($(tail -1 e2fsck-0.txt))" > result.txt
sha256sum disk.img | cut -d' ' -f1 > disk-before.sha256
rm -f mon.sock
t0=$(date +%s.%N)
timeout 90 qemu-system-x86_64 -accel tcg -cpu qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm -m 256M \
  -display none -no-reboot -parallel none -serial file:serial.raw -monitor unix:mon.sock,server,nowait \
  -kernel "$K" -drive file=disk.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
  -append "/bin/busybox sh /etc/t-cyb-init" > qemu-stdout.txt 2>&1 &
qp=$!
python3 - "$OUT" <<'PY' &
import socket, sys, time
time.sleep(2.5)
try:
    s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1] + "/mon.sock")
    s.sendall(b"screendump " + sys.argv[1].encode() + b"/screendump-mid.ppm\n"); time.sleep(0.5); s.close()
except Exception as e:
    open(sys.argv[1] + "/screendump.err", "w").write(str(e))
PY
wait $qp; q=$?
echo "qemu exit=$q wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))") (boot to poweroff, includes the 3 s guest sleep)" >> result.txt
wait
sha256sum disk.img | cut -d' ' -f1 > disk-after.sha256
$S/e2fsck -fn disk.img > e2fsck-1.txt 2>&1; e1=$?
tr -d '\r\0' < serial.raw | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1bc//g' | grep -v "^STAND-IN frame\|[░▒▓█]" > serial-text.log
python3 "$HERE/check.py" serial.raw "$SI/frames.json" "$HERE/refused-by-design.txt" >> result.txt; c=$?
ok=1; [ $c = 0 ] || ok=0
if [ "$(cat disk-before.sha256)" = "$(cat disk-after.sha256)" ] && [ $e1 = 0 ]; then echo "PASS (x) disk unchanged, e2fsck clean" >> result.txt; else echo "FAIL (x) disk changed or e2fsck unclean" >> result.txt; ok=0; fi
if [ -f screendump-mid.ppm ]; then echo "screendump (e, not gated): $(head -c 20 screendump-mid.ppm | head -2 | tr '\n' ' ') sha256 $(sha256sum screendump-mid.ppm | cut -c1-16)… (kept on the box, not committed)" >> result.txt; else echo "screendump (e, not gated): none ($(cat screendump.err 2>/dev/null))" >> result.txt; fi
echo "serial.raw $(stat -c %s serial.raw) bytes" >> result.txt
[ $ok = 1 ] && echo "M4 RUN PASS ((a)-(d),(x); (e) open)" >> result.txt || echo "M4 RUN FAIL" >> result.txt
rm -rf root; cat result.txt
