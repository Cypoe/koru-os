#!/usr/bin/env bash
# M3 acceptance (TCG only, B1). One disk, two unikernels:
#   1. host: mke2fs -d puts static-PIE busybox (+ applet symlinks) on an ext2 image;
#   2. M2 guest (koru/ext2 Koru lift) allocates and writes /dod1 on that image;
#   3. host: e2fsck -fn clean, debugfs cat /dod1 == pattern;
#   4. M3 guest boots with that image as its vfscore root (koruext2fs) and runs a
#      scripted serial session: ls /, cat /dod1, sha256sum /dod1, a pipeline, exit 3;
#   5. checks: dod1 listed, guest sha256 == host pattern sha256, exit status 3 reported
#      by the unikernel, disk byte-identical across the read-only M3 boot.
# The console echoes each typed line and the line editor echoes it again, so a typed
# "ls /" appears as "llss  //" in the log; the checks match that.
# Usage: run-acceptance.sh <M2 kernel> <M3 kernel> <busybox> <outdir>
set -u
M2K=$1; M3K=$2; BB=$3; OUT=$4; S=/usr/sbin
QEMU="timeout 120 qemu-system-x86_64 -accel tcg -cpu qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm -nographic -no-reboot -display none -parallel none"
rm -rf "$OUT"; mkdir -p "$OUT/root/bin" "$OUT/root/tmp" "$OUT/root/dev"; cd "$OUT"
cp "$BB" root/bin/busybox
(cd root/bin && for a in $(./busybox --list); do [ "$a" = busybox ] || ln -sf busybox "$a"; done)
$S/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 512 -O none -L koru-root -E root_owner=0:0 -d root disk.img 8192 2>/dev/null
$S/e2fsck -fn disk.img > e2fsck-0-mkfs.txt 2>&1; echo "mkfs e2fsck exit=$?" > result.txt
$S/dumpe2fs -h disk.img 2>/dev/null > dumpe2fs-0.txt
# --- step 2: M2 guest writes /dod1
t0=$(date +%s.%N)
$QEMU -m 64M -kernel "$M2K" -drive file=disk.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 > m2-serial.raw 2>&1
echo "M2 guest qemu exit=$? wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))")" >> result.txt
tr -d '\r\0' < m2-serial.raw | sed 's/^Booting from ROM\.\.//; s/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1bc//g' > m2-serial.log
grep -q "M2 guest: complete" m2-serial.log && echo "M2 guest: complete" >> result.txt || echo "M2 guest: NOT complete" >> result.txt
# --- step 3: host checks
$S/e2fsck -fn disk.img > e2fsck-1-after-m2.txt 2>&1; e1=$?; echo "after M2: e2fsck -fn exit=$e1 ($(tail -1 e2fsck-1-after-m2.txt))" >> result.txt
$S/debugfs -R "cat /dod1" disk.img > dod1-host.bin 2>/dev/null
$S/dumpe2fs -h disk.img 2>/dev/null > dumpe2fs-1.txt
python3 - >> result.txt <<'PY'
import hashlib
exp=bytes((10 if i%64==63 else ord('a')+((i*7+i//1024)%26)) for i in range(10000))
got=open("dod1-host.bin","rb").read()
open("pattern.sha256","w").write(hashlib.sha256(exp).hexdigest())
print("after M2: debugfs cat /dod1 %d bytes, %s; pattern sha256 %s" % (len(got), "equal to pattern" if got==exp else "DIFFERENT", hashlib.sha256(exp).hexdigest()))
open("dod1.ok","w").write("1" if got==exp else "0")
PY
sha256sum disk.img | cut -d' ' -f1 > disk-before-m3.sha256
# --- step 4: M3 guest on the ext2 root
t0=$(date +%s.%N)
(sleep 4; for c in 'ls /' 'cat /dod1' 'sha256sum /dod1' 'wc -c /dod1' 'ls -l /dod1 /bin/busybox' 'echo hello | tr a-z A-Z' 'exit 3'; do printf '%s\n' "$c"; sleep 2; done; sleep 4) | \
  $QEMU -m 256M -kernel "$M3K" -drive file=disk.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 -append "/bin/busybox sh" > m3-serial.raw 2>&1
q=$?; echo "M3 guest qemu exit=$q wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))") (includes the scripted 2 s pauses)" >> result.txt
tr -d '\r\0' < m3-serial.raw | sed 's/^Booting from ROM\.\.//; s/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1bc//g' > m3-serial.log
sha256sum disk.img | cut -d' ' -f1 > disk-after-m3.sha256
$S/e2fsck -fn disk.img > e2fsck-2-after-m3.txt 2>&1; e2=$?
# --- step 5: verdicts
ok=1
chk() { if eval "$2"; then echo "PASS $1" >> result.txt; else echo "FAIL $1" >> result.txt; ok=0; fi; }
chk "M2 wrote /dod1, host e2fsck clean, debugfs equals pattern" '[ $e1 = 0 ] && [ "$(cat dod1.ok)" = 1 ] && grep -q "M2 guest: complete" m2-serial.log'
chk "M3 ls / lists dod1 and bin" 'grep -A3 "^~ # llss  //$" m3-serial.log | grep -q "dod1" && grep -A3 "^~ # llss  //$" m3-serial.log | grep -qw "bin"'
chk "M3 cat /dod1 shows the pattern" 'grep -q "^$(python3 -c "print(\"\".join(chr(ord(\"a\")+((i*7)%26)) for i in range(63)))")$" m3-serial.log'
chk "M3 sha256sum /dod1 equals host pattern sha256" 'grep -q "^$(cat pattern.sha256)  /dod1" m3-serial.log'
chk "M3 wc -c /dod1 = 10000" 'grep -q "^10000 /dod1" m3-serial.log'
chk "M3 pipeline" 'grep -q "^HELLO$" m3-serial.log'
chk "M3 exit 3 observed as init exit status 3" 'grep -q "koru-os: init exited with status 3" m3-serial.log'
chk "M3 no crash" '! grep -q "Unikraft Crash" m3-serial.log'
chk "disk unchanged by read-only M3 boot, e2fsck still clean" '[ "$(cat disk-before-m3.sha256)" = "$(cat disk-after-m3.sha256)" ] && [ $e2 = 0 ]'
[ $ok = 1 ] && echo "M3 ACCEPTANCE PASS" >> result.txt || echo "M3 ACCEPTANCE FAIL" >> result.txt
rm -rf root dod1.ok; cat result.txt
