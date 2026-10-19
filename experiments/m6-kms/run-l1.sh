#!/usr/bin/env bash
# M6 L1 oracle run (TCG): Debian linux-image 6.12.113 + bochs-drm, initramfs with busybox,
# kmsdumb, modetest, strace. Same screendump points as run-m6.sh. Never counted as a pass.
# Usage: run-l1.sh <extracted linux-image deb dir> <dir with ko/ + modorder.txt> <busybox> <libdrm-tests root> <outdir>
set -u
KX=$1; KO=$2; BB=$3; DRM=$4; OUT=$5; HERE=$(cd "$(dirname "$0")" && pwd)
rm -rf "$OUT"; mkdir -p "$OUT"/ir/{bin,dev,proc,sys,tmp,lib64,usr/bin,lib/x86_64-linux-gnu,ko}; cd "$OUT"
cp "$BB" ir/bin/busybox; cp "$HERE/l1-init" ir/init; chmod 755 ir/init
gcc -O2 -Wall -fPIE -pie -I/usr/include/drm -o ir/bin/kmsdumb "$HERE/kmsdumb.c"
cp "$DRM/usr/bin/modetest" ir/usr/bin/; cp -L "$DRM/usr/lib/x86_64-linux-gnu/libdrm.so.2" ir/lib/x86_64-linux-gnu/
cp /usr/bin/strace ir/bin/strace; cp -L /lib64/ld-linux-x86-64.so.2 ir/lib64/
for b in ir/bin/kmsdumb ir/usr/bin/modetest /usr/bin/strace; do LD_LIBRARY_PATH=$DRM/usr/lib/x86_64-linux-gnu ldd "$b" | awk '$3 ~ /^\// {print $3}'; done | sort -u | grep -v libdrm | while read -r l; do cp -L "$l" ir/lib/x86_64-linux-gnu/; done
cp "$KO"/ko/*.ko ir/ko/; cp "$KO/modorder.txt" ir/
python3 "$HERE/mkcpio.py" ir | gzip -1 > initrd.gz
rm -f mon.sock serial.raw; t0=$(date +%s.%N)
timeout 300 qemu-system-x86_64 -accel tcg -cpu qemu64 -m 512M -display none -vga none -device bochs-display \
  -no-reboot -parallel none -serial file:serial.raw -monitor unix:mon.sock,server,nowait \
  -kernel "$KX"/boot/vmlinuz-* -initrd initrd.gz -append "console=ttyS0 quiet panic=-1" > qemu-stdout.txt 2>&1 &
qp=$!
python3 - "$OUT" "$qp" <<'PY'
import socket, sys, time, os
out = sys.argv[1]; qpid = int(sys.argv[2])
marks = [("kmsdumb: PHASE A", "shot-A.ppm"), ("kmsdumb: PHASE B", "shot-B.ppm"), ("setting mode", "shot-SMPTE.ppm")]
t0 = time.time(); log = open(out + "/shots.txt", "w")
while marks and time.time() - t0 < 290:
    try: txt = open(out + "/serial.raw", "rb").read().decode("utf-8", "replace")
    except FileNotFoundError: txt = ""
    m, f = marks[0]
    if m in txt:
        time.sleep(1.0)
        s = socket.socket(socket.AF_UNIX); s.connect(out + "/mon.sock")
        s.sendall(b"screendump " + (out + "/" + f).encode() + b"\n"); time.sleep(0.7); s.close()
        log.write("%s at %.2f s after QEMU start\n" % (f, time.time() - t0)); marks.pop(0); continue
    if "l1-init: done" in txt: break
    try: os.kill(qpid, 0)
    except OSError: break
    time.sleep(0.1)
for m, f in marks: log.write("%s not taken\n" % f)
PY
wait $qp; echo "qemu exit=$? wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))")" > result.txt
tr -d '\r' < serial.raw > serial.log
for k in A B SMPTE; do [ -f shot-$k.ppm ] && python3 "$HERE/expected.py" shot-$k.ppm $k 1024x768 >> result.txt; done
python3 - <<'PY' >> result.txt
import re
t = open("serial.log", errors="replace").read()
for f in ("kmsdumb", "modetest"):
    m = re.search(r"==== STRACE %s\n(.*?)==== END %s" % (f, f), t, re.S)
    if not m: print("no strace for", f); continue
    open("%s.strace" % f, "w").write(m.group(1))
    io = re.findall(r'ioctl\(\d+, (DRM_IOCTL_\w+)', m.group(1))
    hist = {}
    for x in io: hist[x] = hist.get(x, 0) + 1
    print("L1 %s DRM ioctls: %s" % (f, ", ".join("%s x%d" % kv for kv in sorted(hist.items()))))
PY
rm -rf ir initrd.gz; cat shots.txt result.txt
