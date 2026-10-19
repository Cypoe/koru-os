#!/usr/bin/env bash
# M7b L1 oracle run (TCG): Debian linux-image 6.12 + evdev.ko + bochs-drm modules, initramfs
# with busybox, systemd-udevd/udevadm 257 (udev database) and libinput 1.28.1 debug-events
# under strace; same QMP key injection (drive.py). Never counted as a pass. Extracts the udev
# database records and the /sys, /run, /dev paths libinput touched.
# LIBUDEV=debian (default: systemd libudev + udevd) or LIBUDEV=zero (libudev-zero, no udevd).
# Usage: [LIBUDEV=..] run-l1.sh <kernel deb dir> <ko dir> <modorder> <evdev.ko> <busybox> <m7bin root> <udev root> <libudev-zero .so> <outdir>
set -u
KX=$1; KO=$2; MO=$3; EVKO=$4; BB=$5; LI=$6; UD=$7; UDZ=$8; OUT=$9; HERE=$(cd "$(dirname "$0")" && pwd)
LIBUDEV=${LIBUDEV:-debian}
rm -rf "$OUT"; mkdir -p "$OUT"/ir/{bin,dev,proc,sys,tmp,ko}; cd "$OUT"
UDEV=$UD "$HERE/mkroot.sh" "$LI" ir
cp "$BB" ir/bin/busybox; cp "$HERE/l1-init" ir/init; chmod 755 ir/init
cp /usr/bin/strace ir/bin/strace
ldd /usr/bin/strace | awk '$3 ~ /^\// {print $3}' | while read -r l; do cp -L "$l" ir/lib/x86_64-linux-gnu/; done
cp "$EVKO" ir/ko/evdev.ko; cp "$KO"/*.ko ir/ko/; cp "$MO" ir/modorder.txt
ln -s ../../lib/x86_64-linux-gnu ir/usr/lib/x86_64-linux-gnu
mkdir -p ir/etc inc && cp "$(dirname "$UDZ")/udev.h" inc/libudev.h
gcc -O2 -Wall -Iinc -o ir/bin/udevprobe "$HERE/udevprobe.c" "$UDZ"; rm -rf inc
[ "$LIBUDEV" = zero ] && { cp "$UDZ" ir/lib/x86_64-linux-gnu/libudev.so.1; touch ir/etc/libudev-zero; }
echo "libudev=$LIBUDEV" > libudev.txt
python3 "$HERE/mkcpio.py" ir | gzip -1 > initrd.gz
rm -f qmp.sock serial.raw; t0=$(date +%s.%N)
timeout 400 qemu-system-x86_64 -accel tcg -cpu qemu64 -m 1G -display none -vga none -device bochs-display \
  -no-reboot -parallel none -serial file:serial.raw -qmp unix:qmp.sock,server,nowait \
  -kernel "$KX"/boot/vmlinuz-* -initrd initrd.gz -append "console=ttyS0 quiet panic=-1" > qemu-stdout.txt 2>&1 &
qp=$!
python3 "$HERE/drive.py" "$OUT" "$qp" 390 --no-quit
wait $qp; echo "libudev=$LIBUDEV qemu exit=$? wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))")" > result.txt
tr -d '\r' < serial.raw > serial.log
python3 - <<'PY' >> result.txt
import re
t = open("serial.log", errors="replace").read()
for f, body in re.findall(r"==== UDEVDB (\S+)\n(.*?)==== END", t, re.S):
    open("udevdb-" + f.split("/")[-1].replace(":", "_") + ".txt", "w").write(body)
ue = re.findall(r"==== UEVENT (\S+)\n(.*?)==== END", t, re.S)
open("sysfs-uevents.txt", "w").write("".join("## %s\n%s" % u for u in ue))
m = re.search(r"==== STRACE libinput\n(.*?)==== END libinput", t, re.S)
if m:
    open("libinput.strace", "w").write(m.group(1))
    paths = sorted(set(re.findall(r'"(/(?:sys|run|dev)[^"]*)"', m.group(1))))
    open("libinput-paths.txt", "w").write("\n".join(paths) + "\n")
    print("L1 libinput distinct /sys,/run,/dev paths: %d" % len(paths))
print("L1 libinput KEYBOARD_KEY lines: %d" % len(re.findall(r"KEYBOARD_KEY", t)))
PY
rm -rf ir initrd.gz; cat result.txt
