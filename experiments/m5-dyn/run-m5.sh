#!/usr/bin/env bash
# M5a acceptance run (DESIGN-0001 "M5a acceptance", TCG only). Usage:
#   run-m5.sh <kernel> <inputs dir from build-inputs.sh> <outdir>
set -u
K=$1; IN=$2; OUT=$3; S=/usr/sbin; HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$OUT"; mkdir -p "$OUT"/root/{bin,etc,tmp,dev,lib,lib64,usr/bin,lib/x86_64-linux-gnu}; cd "$OUT"
cp "$IN/busybox-dyn" root/bin/busybox
(cd root/bin && for a in $(./busybox --list); do [ "$a" = busybox ] || ln -sf busybox "$a"; done)
cp "$IN/hello-musl" "$IN/hello-glibc" root/bin/
cp -L /lib64/ld-linux-x86-64.so.2 root/lib64/
# every shared library the dynamic programs need, resolved by the host ldd
for b in "$IN/busybox-dyn" "$IN/hello-glibc" /usr/bin/ls /usr/bin/wc /usr/bin/sha256sum /usr/bin/sort /usr/bin/head; do
  ldd "$b" | awk '$3 ~ /^\// {print $3}'; done | sort -u | while read -r l; do cp -L "$l" root/lib/x86_64-linux-gnu/; done
ls root/lib/x86_64-linux-gnu > libs.txt
cp -L /lib/ld-musl-x86_64.so.1 root/lib/ld-musl-x86_64.so.1
for u in ls wc sha256sum sort head; do cp /usr/bin/$u root/usr/bin/; done
python3 -c "
import random; r=random.Random(5)
open('root/etc/m5-data','w').write(''.join('%08x line %d\n'%(r.getrandbits(32),i) for i in range(500)))"
# host-side expectations, from the same files
mkdir -p root/lost+found  # mke2fs -d keeps it; the guest lists it
ls -1 root > exp-ls.txt; echo $(($(wc -l < exp-ls.txt))) > exp-count.txt
sha256sum root/etc/m5-data | cut -d' ' -f1 > exp-sha.txt
LC_ALL=C sort root/etc/m5-data | head -3 > exp-sort3.txt
{ /usr/bin/ls --version | head -1; ldd --version | head -1; dpkg -s musl 2>/dev/null | grep ^Version; } > host-versions.txt
$S/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 1024 -O none -L koru-root -E root_owner=0:0 -d root disk.img 32768 2>/dev/null
$S/e2fsck -fn disk.img > e2fsck-0.txt 2>&1; echo "mkfs e2fsck exit=$? ($(tail -1 e2fsck-0.txt))" > result.txt
sha256sum disk.img | cut -d' ' -f1 > disk-before.sha256
t0=$(date +%s.%N)
(sleep 4
 for c in 'echo M5-T1; /bin/hello-musl a b; echo rc=$?' 'echo M5-T2; /bin/hello-glibc a; echo rc=$?' \
          'echo M5-T3; /usr/bin/ls /' 'echo M5-T4; /usr/bin/ls / | /usr/bin/wc -l' 'echo M5-T5; ls / | wc -l' \
          'echo M5-T6; /usr/bin/sha256sum /etc/m5-data' 'echo M5-T7; /usr/bin/sort /etc/m5-data | /usr/bin/head -3' 'exit 5'; do
   printf '%s\n' "$c"; sleep 3; done; sleep 3) | \
 timeout 120 qemu-system-x86_64 -accel tcg -cpu qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm -m 256M -nographic -no-reboot -display none -parallel none \
   -kernel "$K" -drive file=disk.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 -append "/bin/busybox sh" > serial.raw 2>&1
echo "qemu exit=$? wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))") (includes the scripted 3 s pauses)" >> result.txt
tr -d '\r\0' < serial.raw | sed 's/^Booting from ROM\.\.//; s/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1bc//g' > serial.log
sha256sum disk.img | cut -d' ' -f1 > disk-after.sha256
$S/e2fsck -fn disk.img > e2fsck-1.txt 2>&1; e1=$?
python3 "$HERE/check.py" serial.log . "$HERE/refused-by-design.txt" >> result.txt; c=$?
ok=1; [ $c = 0 ] || ok=0
if [ "$(cat disk-before.sha256)" = "$(cat disk-after.sha256)" ] && [ $e1 = 0 ]; then echo "PASS (x) disk unchanged, e2fsck clean" >> result.txt; else echo "FAIL (x) disk changed or e2fsck unclean" >> result.txt; ok=0; fi
[ $ok = 1 ] && echo "M5a RUN PASS" >> result.txt || echo "M5a RUN FAIL" >> result.txt
rm -rf root disk.img; cat result.txt
