#!/usr/bin/env bash
# M8a run (DESIGN-0001 §0.4 "M8a acceptance", TCG only). Usage:
#   run-m8.sh <kernel> <busybox (static)> <m8in root (glvnd EGL/GLES debs)> <outdir> [mem]
# ext2 root: busybox, gloff, glvnd + Mesa 25.0.7 (EGL, gallium/llvmpipe, LLVM 19), glibc.
set -u
K=$1; BB=$2; IN=$3; OUT=$4; MEM=${5:-1G}; S=/usr/sbin; HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$OUT"; mkdir -p "$OUT"/root/{bin,etc,tmp,dev}; cd "$OUT"
cp "$BB" root/bin/busybox
(cd root/bin && for a in $(./busybox --list); do [ "$a" = busybox ] || ln -sf busybox "$a"; done)
"$HERE/mkroot.sh" "$IN" root
cp "$HERE/m8-init" root/etc/m8-init; chmod 755 root/etc/m8-init
(cd root && sha256sum bin/gloff lib/x86_64-linux-gnu/libgallium-*.so lib/x86_64-linux-gnu/libLLVM.so.19.1 lib/x86_64-linux-gnu/libEGL_mesa.so.0) > inputs.sha256
$S/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 2048 -O none -L koru-root -E root_owner=0:0 -d root disk.img 262144 2>/dev/null
$S/e2fsck -fn disk.img > e2fsck-0.txt 2>&1; echo "mkfs e2fsck exit=$? ($(tail -1 e2fsck-0.txt))" > result.txt
sha256sum disk.img | cut -d' ' -f1 > disk-before.sha256
t0=$(date +%s.%N)
timeout 900 qemu-system-x86_64 -accel tcg -cpu qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm -m "$MEM" \
  -display none -vga none -device bochs-display -no-reboot -parallel none -serial file:serial.raw \
  -kernel "$K" -drive file=disk.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
  -append "/bin/busybox sh /etc/m8-init" > qemu-stdout.txt 2>&1
q=$?
echo "qemu exit=$q wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))") (boot to poweroff)" >> result.txt
sha256sum disk.img | cut -d' ' -f1 > disk-after.sha256
$S/e2fsck -fn disk.img > e2fsck-1.txt 2>&1; e1=$?
tr -d '\r\0' < serial.raw > serial.log
ok=1
if [ -f "$HERE/check.py" ]; then python3 "$HERE/check.py" . "$HERE/refused-by-design.txt" >> result.txt || ok=0; else ok=0; fi
if [ "$(cat disk-before.sha256)" = "$(cat disk-after.sha256)" ] && [ $e1 = 0 ]; then echo "PASS (x) disk unchanged, e2fsck clean" >> result.txt; else echo "FAIL (x) disk changed or e2fsck unclean" >> result.txt; ok=0; fi
[ $ok = 1 ] && echo "M8 RUN PASS" >> result.txt || echo "M8 RUN FAIL" >> result.txt
rm -rf root disk.img; cat result.txt
