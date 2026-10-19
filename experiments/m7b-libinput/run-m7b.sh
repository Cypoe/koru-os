#!/usr/bin/env bash
# M7b run (DESIGN-0001 §0.4 "M7b acceptance", TCG only). Usage:
#   [LIBUDEV=zero|debian] run-m7b.sh <kernel> <busybox (static)> <m7bin root> <libudev-zero .so> <outdir>
# ext2 root: busybox, udevprobe, unmodified Debian libinput 1.28.1 tools and libraries, glibc,
# and libudev.so.1 = libudev-zero (default) or Debian's systemd libudev (LIBUDEV=debian, probe
# only). Mount points /sys (the kernel's sysfs view) and /run exist in the image. Keys are
# injected through QMP (drive.py), then the checks run (check.py).
set -u
K=$1; BB=$2; LI=$3; UDZ=$4; OUT=$5; S=/usr/sbin; HERE=$(cd "$(dirname "$0")" && pwd)
LIBUDEV=${LIBUDEV:-zero}
rm -rf "$OUT"; mkdir -p "$OUT"/root/{bin,etc,tmp,dev,sys,run,proc}; cd "$OUT"
"$HERE/mkroot.sh" "$LI" root
cp "$BB" root/bin/busybox
(cd root/bin && for a in $(./busybox --list); do [ "$a" = busybox ] || ln -sf busybox "$a"; done)
mkdir -p inc && cp "$(dirname "$UDZ")/udev.h" inc/libudev.h
gcc -O2 -Wall -Iinc -o root/bin/udevprobe "$HERE/udevprobe.c" "$UDZ"
[ "$LIBUDEV" = zero ] && cp "$UDZ" root/lib/x86_64-linux-gnu/libudev.so.1
mkdir -p root/usr/lib && ln -s ../../lib/x86_64-linux-gnu root/usr/lib/x86_64-linux-gnu
cp "$HERE/m7b-init" root/etc/m7b-init; chmod 755 root/etc/m7b-init
sha256sum root/bin/udevprobe root/usr/libexec/libinput/libinput-debug-events root/usr/bin/libinput \
  root/lib/x86_64-linux-gnu/libinput.so.10 root/lib/x86_64-linux-gnu/libudev.so.1 > inputs.sha256
echo "libudev=$LIBUDEV" > result.txt
$S/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 4096 -O none -L koru-root -E root_owner=0:0 -d root disk.img 65536 2>/dev/null
$S/e2fsck -fn disk.img > e2fsck-0.txt 2>&1; echo "mkfs e2fsck exit=$? ($(tail -1 e2fsck-0.txt))" >> result.txt
sha256sum disk.img | cut -d' ' -f1 > disk-before.sha256
rm -f qmp.sock serial.raw
t0=$(date +%s.%N)
timeout 200 qemu-system-x86_64 -accel tcg -cpu qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm -m 512M \
  -display none -vga none -device bochs-display -no-reboot -parallel none -serial file:serial.raw \
  -qmp unix:qmp.sock,server,nowait \
  -kernel "$K" -drive file=disk.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
  -append "/bin/busybox sh /etc/m7b-init" > qemu-stdout.txt 2>&1 &
qp=$!
python3 "$HERE/drive.py" "$OUT" "$qp" 190
wait $qp; q=$?
echo "qemu exit=$q wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))") (boot to QMP quit)" >> result.txt
sha256sum disk.img | cut -d' ' -f1 > disk-after.sha256
$S/e2fsck -fn disk.img > e2fsck-1.txt 2>&1; e1=$?
tr -d '\r\0' < serial.raw | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1bc//g' > serial.log
ok=1
if [ -f "$HERE/check.py" ]; then python3 "$HERE/check.py" . "$HERE/refused-by-design.txt" >> result.txt || ok=0; else ok=0; fi
if [ "$(cat disk-before.sha256)" = "$(cat disk-after.sha256)" ] && [ $e1 = 0 ]; then echo "PASS (x) disk unchanged, e2fsck clean" >> result.txt; else echo "FAIL (x) disk changed or e2fsck unclean" >> result.txt; ok=0; fi
[ $ok = 1 ] && echo "M7b RUN PASS" >> result.txt || echo "M7b RUN FAIL" >> result.txt
rm -rf root disk.img inc; cat result.txt
