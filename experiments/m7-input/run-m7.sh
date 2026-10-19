#!/usr/bin/env bash
# M7 run (DESIGN-0001 §0.4 "M7 acceptance", TCG only). Usage:
#   run-m7.sh <kernel> <busybox (static)> <evtest root (fetch: apt-get download evtest)> <outdir>
# Builds an ext2 root (busybox, evdump, unmodified evtest, glibc), boots with the i440fx
# PS/2 controller, injects keys through QMP input-send-event (drive.py), then checks.
set -u
K=$1; BB=$2; EVT=$3; OUT=$4; S=/usr/sbin; HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$OUT"; mkdir -p "$OUT"/root/{bin,etc,tmp,dev,lib64,usr/bin,lib/x86_64-linux-gnu}; cd "$OUT"
cp "$BB" root/bin/busybox
(cd root/bin && for a in $(./busybox --list); do [ "$a" = busybox ] || ln -sf busybox "$a"; done)
gcc -O2 -Wall -fPIE -pie -o root/bin/evdump "$HERE/evdump.c"
cp "$EVT/usr/bin/evtest" root/usr/bin/
cp -L /lib64/ld-linux-x86-64.so.2 root/lib64/
for b in root/bin/evdump root/usr/bin/evtest; do ldd "$b" | awk '$3 ~ /^\// {print $3}'; done | sort -u | while read -r l; do cp -L "$l" root/lib/x86_64-linux-gnu/; done
cp "$HERE/m7-init" root/etc/m7-init; chmod 755 root/etc/m7-init
sha256sum root/bin/evdump root/usr/bin/evtest > inputs.sha256
$S/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 1024 -O none -L koru-root -E root_owner=0:0 -d root disk.img 16384 2>/dev/null
$S/e2fsck -fn disk.img > e2fsck-0.txt 2>&1; echo "mkfs e2fsck exit=$? ($(tail -1 e2fsck-0.txt))" > result.txt
sha256sum disk.img | cut -d' ' -f1 > disk-before.sha256
rm -f qmp.sock serial.raw
t0=$(date +%s.%N)
timeout 150 qemu-system-x86_64 -accel tcg -cpu qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm -m 256M \
  -display none -vga none -device bochs-display -no-reboot -parallel none -serial file:serial.raw \
  -qmp unix:qmp.sock,server,nowait \
  -kernel "$K" -drive file=disk.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
  -append "/bin/busybox sh /etc/m7-init" > qemu-stdout.txt 2>&1 &
qp=$!
python3 "$HERE/drive.py" "$OUT" "$qp" 140
wait $qp; q=$?
echo "qemu exit=$q wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))") (boot to QMP quit)" >> result.txt
sha256sum disk.img | cut -d' ' -f1 > disk-after.sha256
$S/e2fsck -fn disk.img > e2fsck-1.txt 2>&1; e1=$?
tr -d '\r\0' < serial.raw | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1bc//g' > serial.log
ok=1
if [ -f "$HERE/check.py" ]; then python3 "$HERE/check.py" . "$HERE/refused-by-design.txt" >> result.txt || ok=0; else ok=0; fi
if [ "$(cat disk-before.sha256)" = "$(cat disk-after.sha256)" ] && [ $e1 = 0 ]; then echo "PASS (x) disk unchanged, e2fsck clean" >> result.txt; else echo "FAIL (x) disk changed or e2fsck unclean" >> result.txt; ok=0; fi
[ $ok = 1 ] && echo "M7 RUN PASS" >> result.txt || echo "M7 RUN FAIL" >> result.txt
rm -rf root disk.img; cat result.txt
