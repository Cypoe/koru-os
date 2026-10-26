#!/usr/bin/env bash
# build-disk.sh <prog.k> [out.img] — installable media: a partitioned MBR
# disk image whose ext2 root holds /boot/koru.elf + grub.cfg, with GRUB
# i386-pc written into the MBR + post-MBR gap by grub-install.
# SeaBIOS -> MBR boot.img -> core.img -> partition /boot/grub -> mb2 is
# the chain a real install takes — QEMU -kernel/PVH exercises none of it,
# and -cdrom never touches a partition table or an MBR boot record.
# Needs WSL: parted losetup mkfs.ext2 grub-install (grub-pc-bin).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROG="${1:?usage: build-disk.sh <prog.k> [out.img]}"
OUT="${2:-koru-disk.img}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

bash "$ROOT/scripts/build-native.sh" "$PROG" "$WORK/koru.elf" \
    > "$WORK/native.build" 2>&1 || {
    echo "build-disk: kernel build failed"; tail -10 "$WORK/native.build"; exit 1;
}

# GRUB on COM1 — the loader's own banner is part of the boot evidence.
cat > "$WORK/grub.cfg" <<'CFG'
serial --speed=115200 --unit=0
terminal_input serial
terminal_output serial
set timeout=0
menuentry "koru-os" {
    echo "GRUB: multiboot2 /boot/koru.elf"
    insmod multiboot2
    multiboot2 /boot/koru.elf
    boot
}
CFG

WDIR="$(wsl -e wslpath -u "$(cygpath -w "$WORK")")"
WOUT="$(wsl -e wslpath -u "$(cygpath -w "$OUT")")"
# The whole disk surgery runs privileged inside WSL: partition the file,
# loop-mount p1, lay /boot, then grub-install writes the MBR + core gap.
# MSYS_NO_PATHCONV: /mnt/c/... args must reach wsl.exe untouched.
MSYS_NO_PATHCONV=1 wsl -u root bash -s -- "$WDIR" "$WOUT" <<'EOS'
set -e
WDIR="$1"; WOUT="$2"
IMG="$WDIR/disk.img"
dd if=/dev/zero of="$IMG" bs=1M count=64 status=none
parted -s "$IMG" mklabel msdos mkpart primary ext2 1MiB 100%
LOOP="$(losetup -fP --show "$IMG")"
cleanup() { umount /mnt/koru-inst 2>/dev/null; losetup -d "$LOOP" 2>/dev/null || true; }
trap cleanup EXIT
mkfs.ext2 -q "${LOOP}p1"
mkdir -p /mnt/koru-inst
mount "${LOOP}p1" /mnt/koru-inst
mkdir -p /mnt/koru-inst/boot/grub
cp "$WDIR/koru.elf" /mnt/koru-inst/boot/koru.elf
cp "$WDIR/grub.cfg" /mnt/koru-inst/boot/grub/grub.cfg
grub-install --target=i386-pc --root-directory=/mnt/koru-inst \
    --no-floppy --modules="part_msdos ext2 normal linux serial multiboot2" \
    "$LOOP"
sync
cp "$IMG" "$WOUT"
EOS
echo "build-disk: $OUT written — boot with: qemu-system-x86_64 -drive file=$OUT,format=raw,if=ide -serial stdio -display none"
