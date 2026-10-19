#!/usr/bin/env bash
# M7 L1 oracle run (TCG): Debian linux-image 6.12.113 (i8042 + atkbd built in) + evdev.ko,
# initramfs with busybox, evdump (under strace), unmodified evtest; same QMP key
# injection (drive.py) as run-m7.sh. Never counted as a pass.
# Usage: run-l1.sh <extracted linux-image deb dir> <evdev.ko> <busybox> <evtest root> <outdir>
set -u
KX=$1; EVKO=$2; BB=$3; EVT=$4; OUT=$5; HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$OUT"; mkdir -p "$OUT"/ir/{bin,dev,proc,sys,tmp,lib64,usr/bin,lib/x86_64-linux-gnu,ko}; cd "$OUT"
cp "$BB" ir/bin/busybox; cp "$HERE/l1-init" ir/init; chmod 755 ir/init
gcc -O2 -Wall -fPIE -pie -o ir/bin/evdump "$HERE/evdump.c"
cp "$EVT/usr/bin/evtest" ir/usr/bin/; cp /usr/bin/strace ir/bin/strace; cp -L /lib64/ld-linux-x86-64.so.2 ir/lib64/
for b in ir/bin/evdump ir/usr/bin/evtest /usr/bin/strace; do ldd "$b" | awk '$3 ~ /^\// {print $3}'; done | sort -u | while read -r l; do cp -L "$l" ir/lib/x86_64-linux-gnu/; done
cp "$EVKO" ir/ko/evdev.ko
python3 "$HERE/mkcpio.py" ir | gzip -1 > initrd.gz
rm -f qmp.sock serial.raw; t0=$(date +%s.%N)
timeout 300 qemu-system-x86_64 -accel tcg -cpu qemu64 -m 512M -display none -vga none -device bochs-display \
  -no-reboot -parallel none -serial file:serial.raw -qmp unix:qmp.sock,server,nowait \
  -kernel "$KX"/boot/vmlinuz-* -initrd initrd.gz -append "console=ttyS0 quiet panic=-1" > qemu-stdout.txt 2>&1 &
qp=$!
python3 "$HERE/drive.py" "$OUT" "$qp" 290
wait $qp; echo "qemu exit=$? wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))")" > result.txt
tr -d '\r' < serial.raw > serial.log
python3 - <<'PY' >> result.txt
import re
t = open("serial.log", errors="replace").read()
m = re.search(r"==== STRACE evdump\n(.*?)==== END evdump", t, re.S)
if m:
    open("evdump.strace", "w").write(m.group(1))
    io = re.findall(r'ioctl\(\d+, (EVIOC\w+(?:\(\d+\))?)', m.group(1))
    print("L1 evdump ioctls: " + ", ".join(sorted(set(io))))
print("L1 evdump events: %d" % len(re.findall(r"^evdump: ev ", t, re.M)))
PY
rm -rf ir initrd.gz; cat result.txt
