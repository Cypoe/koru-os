#!/usr/bin/env bash
# M2 / DoD-1 acceptance (TCG only). Host makes an ext2 image, the guest (koruos/ext2)
# allocates an inode and blocks and writes /dod1, the host checks with e2fsprogs.
# Usage: run.sh <kernel> <outdir> [mke2fs feature set, default "none"]
set -u
K=$1; OUT=$2; FEAT=${3:-none}; S=/usr/sbin
mkdir -p "$OUT"; cd "$OUT"; rm -f disk.img
$S/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 64 -O "$FEAT" -L koru-m2 -E root_owner=0:0 disk.img 4096
$S/dumpe2fs -h disk.img 2>/dev/null > before-dumpe2fs.txt
$S/e2fsck -fn disk.img > before-e2fsck.txt 2>&1; echo "before e2fsck exit=$?" > run.txt
t0=$(date +%s.%N)
timeout 120 qemu-system-x86_64 -accel tcg -kernel "$K" \
  -cpu 'qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm' \
  -m 64M -nographic -no-reboot -display none -parallel none \
  -drive file=disk.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 > serial.raw 2>&1
rc=$?; t1=$(date +%s.%N)
tr -d '\r' < serial.raw | sed 's/^Booting from ROM\.\.//; s/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1bc//g' > serial.log
echo "qemu exit=$rc wall_s=$(python3 -c "print(round($t1-$t0,3))") accel=tcg features=$FEAT" >> run.txt
$S/e2fsck -fn disk.img > after-e2fsck.txt 2>&1; ec=$?; echo "after e2fsck -fn exit=$ec" >> run.txt
$S/debugfs -R "cat /dod1" disk.img > got-dod1.bin 2>/dev/null
$S/debugfs -R "stat /dod1" disk.img > dod1-stat.txt 2>/dev/null
$S/dumpe2fs -h disk.img 2>/dev/null > after-dumpe2fs.txt
python3 - >> run.txt <<'PY'
exp=bytes((10 if i%64==63 else ord('a')+((i*7+i//1024)%26)) for i in range(10000))
got=open("got-dod1.bin","rb").read()
print("debugfs cat /dod1: %d bytes, %s" % (len(got), "equal to pattern" if got==exp else "DIFFERENT"))
def fb(p):
    for l in open(p):
        if l.startswith("Free blocks:"): return int(l.split()[-1])
    return None
def fi(p):
    for l in open(p):
        if l.startswith("Free inodes:"): return int(l.split()[-1])
b0,b1=fb("before-dumpe2fs.txt"),fb("after-dumpe2fs.txt"); i0,i1=fi("before-dumpe2fs.txt"),fi("after-dumpe2fs.txt")
print("free blocks %s -> %s (drop %s), free inodes %s -> %s" % (b0,b1,b0-b1,i0,i1))
ok = got==exp and b0-b1>=10 and i0-i1==1
open("pycheck","w").write("1" if ok else "0")
PY
grep -q "M2 guest: complete" serial.log && echo "serial: M2 guest complete" >> run.txt || echo "serial: guest did NOT complete" >> run.txt
if [ $ec = 0 ] && [ "$(cat pycheck)" = 1 ] && grep -q "M2 guest: complete" serial.log; then echo "M2 PASS" >> run.txt; else echo "M2 FAIL" >> run.txt; fi
rm -f pycheck; cat run.txt; grep -E "^(ext2|FAIL|M2)" serial.log
