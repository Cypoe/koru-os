#!/usr/bin/env bash
# M1 acceptance: koru-libs unikraft/blk writes sector 1 of a real virtio-blk disk
# from inside a Koru-built Unikraft image; the host checks it with cmp.
# Usage: run.sh <kernel> <boot_lifecycle.k> <outdir> <accel: kvm|tcg>
set -u
K=$1; SRC=$2; OUT=$3; ACCEL=$4
mkdir -p "$OUT"; cd "$OUT"
python3 - "$SRC" <<'PY'
import re,sys
src=open(sys.argv[1]).read()
s0=(b"KORU DISK SECTOR ZERO -- planted by the host, read back by "
    b"unikraft/blk from a real virtio-blk device. ")
s0=(s0+b"-"*512)[:512]
open("disk.img","wb").write(s0+b"\x00"*(512*63))
open("expect-s0.bin","wb").write(s0)
m=re.search(r'unikraft/blk:write\(first\.dev, sector: 1, bytes: "([^"]*)"\)',src)
b=m.group(1).encode(); print("write payload bytes:",len(b))
open("expect-s1.bin","wb").write((b+b"\x00"*512)[:512])
open("expect-rest.bin","wb").write(b"\x00"*(512*62))
PY
cp disk.img disk-before.img
ACC="-accel tcg"; [ "$ACCEL" = kvm ] && ACC="-accel kvm"
t0=$(date +%s.%N)
timeout 60 qemu-system-x86_64 $ACC -kernel "$K" \
  -cpu 'qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm' \
  -m 64M -nographic -no-reboot -display none -parallel none \
  -drive file=disk.img,format=raw,if=none,id=d0 \
  -device virtio-blk-pci,drive=d0 > serial.log 2>&1
rc=$?; t1=$(date +%s.%N)
echo "qemu exit=$rc wall_s=$(python3 -c "print(round($t1-$t0,3))") accel=$ACCEL" > run.txt
dd if=disk.img bs=512 skip=0 count=1 status=none of=got-s0.bin
dd if=disk.img bs=512 skip=1 count=1 status=none of=got-s1.bin
dd if=disk.img bs=512 skip=2 count=62 status=none of=got-rest.bin
pass=1
for x in s0 s1 rest; do
  if cmp "expect-$x.bin" "got-$x.bin" >> run.txt 2>&1; then echo "cmp $x: equal" >> run.txt; else echo "cmp $x: DIFFERENT" >> run.txt; pass=0; fi
done
grep -q "lifecycle complete" serial.log && echo "serial: lifecycle complete" >> run.txt || { echo "serial: lifecycle complete MISSING" >> run.txt; pass=0; }
sha256sum "$K" disk-before.img disk.img >> run.txt
[ $pass = 1 ] && echo "M1 PASS" >> run.txt || echo "M1 FAIL" >> run.txt
rm -f disk-before.img
cat run.txt
