#!/usr/bin/env bash
# M8b run (DESIGN-0001 §0.4 "M8b acceptance", TCG only). Usage:
#   run-m8b.sh <kernel> <busybox (static)> <m8in root> <kmscube root> <outdir> [frames]
set -u
K=$1; BB=$2; IN=$3; KR=$4; OUT=$5; FR=${6:-120}; S=/usr/sbin; HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$OUT"; mkdir -p "$OUT"/root/{bin,etc,tmp,dev}; cd "$OUT"
cp "$BB" root/bin/busybox
(cd root/bin && for a in $(./busybox --list); do [ "$a" = busybox ] || ln -sf busybox "$a"; done)
"$HERE/mkroot.sh" "$IN" root "$KR"
sed "s/\${KMSCUBE_FRAMES:-120}/$FR/; s/\${KMSCUBE_SLEEP:-60}/${SLP:-60}/" "$HERE/m8b-init" > root/etc/m8b-init; chmod 755 root/etc/m8b-init
(cd root && sha256sum usr/bin/kmscube lib/x86_64-linux-gnu/libgallium-*.so usr/lib/x86_64-linux-gnu/gbm/dri_gbm.so) > inputs.sha256
$S/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 2048 -O none -L koru-root -E root_owner=0:0 -d root disk.img 262144 2>/dev/null
$S/e2fsck -fn disk.img > e2fsck-0.txt 2>&1; echo "mkfs e2fsck exit=$? ($(tail -1 e2fsck-0.txt))" > result.txt
sha256sum disk.img | cut -d' ' -f1 > disk-before.sha256
rm -f qmp.sock serial.raw; t0=$(date +%s.%N)
timeout 900 qemu-system-x86_64 -accel tcg -cpu qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm -m 1G \
  -display none -vga none -device bochs-display -no-reboot -parallel none -serial file:serial.raw \
  -qmp unix:qmp.sock,server,nowait \
  -kernel "$K" -drive file=disk.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
  -append "/bin/busybox sh /etc/m8b-init" > qemu-stdout.txt 2>&1 &
qp=$!
python3 "$HERE/shots.py" "$OUT" "$qp" 890
wait $qp; q=$?
echo "qemu exit=$q wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))") (boot to poweroff)" >> result.txt
sha256sum disk.img | cut -d' ' -f1 > disk-after.sha256
$S/e2fsck -fn disk.img > e2fsck-1.txt 2>&1; e1=$?
tr -d '\r\0' < serial.raw > serial.log
ok=1
if [ -f "$HERE/check-m8b.py" ]; then python3 "$HERE/check-m8b.py" . "$HERE/refused-by-design.txt" >> result.txt || ok=0; else ok=0; fi
if [ "$(cat disk-before.sha256)" = "$(cat disk-after.sha256)" ] && [ $e1 = 0 ]; then echo "PASS (x) disk unchanged, e2fsck clean" >> result.txt; else echo "FAIL (x) disk changed or e2fsck unclean" >> result.txt; ok=0; fi
[ $ok = 1 ] && echo "M8b RUN PASS" >> result.txt || echo "M8b RUN FAIL" >> result.txt
rm -rf root disk.img; cat result.txt
