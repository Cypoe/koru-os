#!/usr/bin/env bash
# M6 run (DESIGN-0001 §0.4 "M6 acceptance", TCG only). Usage:
#   run-m6.sh <kernel> <busybox (static)> <libdrm-tests root from fetch-inputs.sh> <outdir>
# Builds an ext2 root (busybox, kmsdumb, modetest + libdrm, glibc), boots with -vga none
# -device bochs-display, takes a QMP-monitor screendump at each phase marker, then checks.
set -u
K=$1; BB=$2; DRM=$3; OUT=$4; S=/usr/sbin; HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$OUT"; mkdir -p "$OUT"/root/{bin,etc,tmp,dev,lib64,usr/bin,lib/x86_64-linux-gnu}; cd "$OUT"
cp "$BB" root/bin/busybox
(cd root/bin && for a in $(./busybox --list); do [ "$a" = busybox ] || ln -sf busybox "$a"; done)
gcc -O2 -Wall -fPIE -pie -I/usr/include/drm -o root/bin/kmsdumb "$HERE/kmsdumb.c"
cp "$DRM/usr/bin/modetest" root/usr/bin/
cp -L "$DRM/usr/lib/x86_64-linux-gnu/libdrm.so.2" root/lib/x86_64-linux-gnu/
cp -L /lib64/ld-linux-x86-64.so.2 root/lib64/
for b in root/bin/kmsdumb root/usr/bin/modetest; do
  LD_LIBRARY_PATH=$DRM/usr/lib/x86_64-linux-gnu ldd "$b" | awk '$3 ~ /^\// {print $3}'; done | sort -u | grep -v libdrm | while read -r l; do cp -L "$l" root/lib/x86_64-linux-gnu/; done
cp "$HERE/m6-init" root/etc/m6-init; chmod 755 root/etc/m6-init
sha256sum root/bin/kmsdumb root/usr/bin/modetest root/lib/x86_64-linux-gnu/libdrm.so.2 > inputs.sha256
$S/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 1024 -O none -L koru-root -E root_owner=0:0 -d root disk.img 32768 2>/dev/null
$S/e2fsck -fn disk.img > e2fsck-0.txt 2>&1; echo "mkfs e2fsck exit=$? ($(tail -1 e2fsck-0.txt))" > result.txt
sha256sum disk.img | cut -d' ' -f1 > disk-before.sha256
rm -f mon.sock serial.raw
t0=$(date +%s.%N)
timeout 120 qemu-system-x86_64 -accel tcg -cpu qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm -m 256M \
  -display none -vga none -device bochs-display -no-reboot -parallel none -serial file:serial.raw \
  -monitor unix:mon.sock,server,nowait \
  -kernel "$K" -drive file=disk.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
  -append "/bin/busybox sh /etc/m6-init" > qemu-stdout.txt 2>&1 &
qp=$!
python3 - "$OUT" "$qp" <<'PY'
import socket, sys, time, os
out = sys.argv[1]; qpid = int(sys.argv[2])
marks = [("kmsdumb: PHASE A", "shot-A.ppm"), ("kmsdumb: PHASE B", "shot-B.ppm"),
         ("setting mode", "shot-SMPTE.ppm")]
t0 = time.time(); log = open(out + "/shots.txt", "w")
while marks and time.time() - t0 < 110:
    try: txt = open(out + "/serial.raw", "rb").read().decode("utf-8", "replace")
    except FileNotFoundError: txt = ""
    m, f = marks[0]
    if m in txt:
        time.sleep(1.0)  # let the guest finish the modeset; the phase lasts 3-4 s guest time
        try:
            s = socket.socket(socket.AF_UNIX); s.connect(out + "/mon.sock")
            s.sendall(b"screendump " + (out + "/" + f).encode() + b"\n"); time.sleep(0.7); s.close()
            log.write("%s at %.2f s after QEMU start\n" % (f, time.time() - t0))
        except Exception as e:
            log.write("%s failed: %s\n" % (f, e))
        marks.pop(0); continue
    if "init exited with status" in txt or "Unikraft Crash" in txt: break
    try: os.kill(qpid, 0)
    except OSError: break
    time.sleep(0.1)
for m, f in marks: log.write("%s not taken (marker '%s' not seen)\n" % (f, m))
PY
wait $qp; q=$?
echo "qemu exit=$q wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))") (boot to poweroff, includes 2 x 3 s + 4 s guest pauses)" >> result.txt
sha256sum disk.img | cut -d' ' -f1 > disk-after.sha256
$S/e2fsck -fn disk.img > e2fsck-1.txt 2>&1; e1=$?
tr -d '\r\0' < serial.raw | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1bc//g' > serial.log
python3 "$HERE/check.py" . "$HERE/refused-by-design.txt" >> result.txt; c=$?
ok=1; [ $c = 0 ] || ok=0
if [ "$(cat disk-before.sha256)" = "$(cat disk-after.sha256)" ] && [ $e1 = 0 ]; then echo "PASS (x) disk unchanged, e2fsck clean" >> result.txt; else echo "FAIL (x) disk changed or e2fsck unclean" >> result.txt; ok=0; fi
[ $ok = 1 ] && echo "M6 RUN PASS" >> result.txt || echo "M6 RUN FAIL" >> result.txt
rm -rf root disk.img; cat result.txt
