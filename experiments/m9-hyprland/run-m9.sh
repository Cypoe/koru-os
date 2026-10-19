#!/usr/bin/env bash
# M9 acceptance boot (TCG only; run-probe.sh with the drive-m9.py QMP driver): ext2 image from <root> + static busybox + <init script> at
# /etc/m9-init, boots the M7b kernel with bochs-display and the i8042, waits for
# "m9-init: end" or <timeout s> (default 600), takes a screendump (shot.ppm), then quits QEMU.
# A second, empty 8 MiB virtio-blk disk (snap.img) backs /dev/korusnap; after QEMU exits, a
# stream the guest persisted there is decoded to snap.bin (a tar of the snapshotted /tmp files).
# Usage: run-probe.sh <kernel> <busybox> <root> <init> <outdir> [timeout]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
K=$1; BB=$2; R=$3; INIT=$4; OUT=$5; TMO=${6:-600}; S=/usr/sbin; MEM=${MEM:-2G}
# resolve inputs before cd "$OUT" (a relative <init> used to fail silently and fall back to
# whatever etc/m9-init the root already held)
K=$(realpath "$K"); BB=$(realpath "$BB"); R=$(realpath "$R"); INIT=$(realpath -e "$INIT") || { echo "init not found: $4"; exit 2; }
rm -rf "$OUT"; mkdir -p "$OUT/root"; cd "$OUT"
cp -a "$R/." root/; mkdir -p root/{bin,tmp,dev,sys,run,proc,etc,var/cache}
cp "$BB" root/bin/busybox
(cd root/bin && for a in $(./busybox --list); do [ "$a" = busybox ] || [ -e "$a" ] || ln -s busybox "$a"; done)
cp "$INIT" root/etc/m9-init
kb=$(du -sk root | cut -f1); blocks=$(( kb * 12 / 10 + 32768 ))
$S/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 16384 -O none -L koru-root -E root_owner=0:0 -d root disk.img $blocks 2>/dev/null
echo "image blocks=$blocks" > result.txt
rm -rf root qmp.sock serial.raw snap.img snap.bin; truncate -s 8M snap.img; t0=$(date +%s.%N)
timeout $((TMO + 30)) qemu-system-x86_64 -accel tcg -cpu qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm -m $MEM \
  -display none -vga none -device bochs-display -no-reboot -parallel none -serial file:serial.raw \
  -qmp unix:qmp.sock,server,nowait ${QEMU_EXTRA:-} \
  -kernel "$K" -drive file=disk.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
  -drive file=snap.img,format=raw,if=none,id=d1 -device virtio-blk-pci,drive=d1 \
  -append "/bin/busybox sh /etc/m9-init" > qemu-stdout.txt 2>&1 &
qp=$!
python3 "$HERE/drive-m9.py" "$OUT" "$qp" "$TMO"
wait $qp; echo "qemu exit=$? wall_s=$(python3 -c "print(round($(date +%s.%N)-$t0,3))")" >> result.txt
tr -d '\r\0' < serial.raw | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1bc//g' > serial.log
python3 - <<'PY' >> result.txt
d = open("snap.img", "rb").read()
if d[:10] == b"KORUSNAP1 ":
    n = int(d[10:d.index(b"\n")]); open("snap.bin", "wb").write(d[512:512 + n])
    print("snap bytes=%d" % n)
else:
    print("snap none")
PY
rm -f disk.img snap.img; cat result.txt
