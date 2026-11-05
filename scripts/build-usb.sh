#!/usr/bin/env bash
# build-usb.sh <prog.k> <out.img> [payload ...] — a raw GPT disk image
# whose ESP carries GRUB-EFI + the kernel + module payloads: the
# flash-stick artifact. UEFI firmware reads the FAT32 ESP itself, so
# stage-1 needs NO storage driver — GRUB-EFI (grub-mkstandalone,
# removable path \\EFI\\BOOT\\BOOTX64.EFI) loads /boot/koru.elf via
# multiboot2 and each payload via module2 -> mb2 tag 3, the same
# transport the ISO path proved. dd-able to a stick as-is.
#
# ESP content: EFI/BOOT/BOOTX64.EFI (modules + grub.cfg embedded via
# memdisk — the cfg is build-time anyway since payloads are args) and
# boot/{koru.elf,<payload>...}. The menuentry re-roots onto the ESP by
# searching for /boot/koru.elf so $root is the FAT32 disk, not the
# memdisk the config rode in on.
#
# Layout: [protective MBR + primary GPT @ LBA0][1MiB align][FAT32 ESP]
#         [backup GPT at end]
#
# Needs WSL: grub-mkstandalone, mkfs.vfat, mtools, sgdisk.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROG="${1:?usage: build-usb.sh <prog.k> <out.img> [payload ...]}"
OUT="${2:?usage: build-usb.sh <prog.k> <out.img> [payload ...]}"
shift 2
PAYLOADS=("$@")
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# 1. kernel — same flat mb2/PVH ELF the ISO carries.
bash "$ROOT/scripts/build-native.sh" "$PROG" "$WORK/koru.elf" \
    > "$WORK/native.build" 2>&1 || {
    echo "build-usb: kernel build failed"; tail -10 "$WORK/native.build"; exit 1;
}

# 2. stage ESP content.
mkdir -p "$WORK/stage/EFI/BOOT" "$WORK/stage/boot"
cp "$WORK/koru.elf" "$WORK/stage/boot/koru.elf"
for p in ${PAYLOADS[@]+"${PAYLOADS[@]}"}; do
    cp "$p" "$WORK/stage/boot/$(basename "$p")"
done

# 3. grub.cfg — embedded in BOOTX64.EFI's memdisk at build time.
#    `search --set=root` inside the menuentry pins $root to the ESP
#    (the memdisk has no /boot/koru.elf, so the file search can only
#    land on the FAT32 partition). serial/terminal/efi_gop/module2
#    lines are identical to build-iso.sh's proven cfg.
cat > "$WORK/grub.cfg" <<'CFG'
serial --speed=115200 --unit=0
terminal_input serial
terminal_output serial
set timeout=0
if [ "$grub_platform" = "efi" ]; then
    insmod efi_gop   # GOP modes must exist before multiboot2 tries to
                     # satisfy the fb request — else "no suitable video
                     # mode" and the kernel falls back to BGA
fi
menuentry "koru-os" {
    search --no-floppy --set=root --file /boot/koru.elf
    echo "GRUB: multiboot2 /boot/koru.elf"
    insmod multiboot2
    multiboot2 /boot/koru.elf
CFG
for p in ${PAYLOADS[@]+"${PAYLOADS[@]}"}; do
    # `module2` is GRUB's multiboot2 module command — `module` is the
    # mb1 spelling and refuses under mb2. The tag's string field is a
    # CMDLINE, not the path — pass the basename so the kernel names it.
    echo "    module2 /boot/$(basename "$p") $(basename "$p")" >> "$WORK/grub.cfg"
done
cat >> "$WORK/grub.cfg" <<'CFG'
    boot
}
CFG

# 4. WSL: mkfs.vfat ESP + mtools populate + sgdisk GPT wrap.
WSTAGE="$(wsl -e wslpath -u "$(cygpath -w "$WORK/stage")")"
WCFG="$(wsl -e wslpath -u "$(cygpath -w "$WORK/grub.cfg")")"
WESP="$(wsl -e wslpath -u "$(cygpath -w "$WORK/esp.img")")"
WDISK="$(wsl -e wslpath -u "$(cygpath -w "$OUT")")"
export MSYS_NO_PATHCONV=1
wsl -e bash -lc "
set -e
cd '$WSTAGE'
# ESP: FAT32, 64M — room for kernel + payloads + GRUB.
dd if=/dev/zero of='$WESP' bs=1M count=64
mkfs.vfat -F 32 -n KORU-ESP '$WESP' >/dev/null
# BOOTX64.EFI — every module the chain can touch, cfg embedded on the
# memdisk at /boot/grub/grub.cfg (the standalone's default config path).
grub-mkstandalone -O x86_64-efi \
    --modules='part_gpt fat normal configfile search search_fs_file search_label echo test true ls cat serial terminfo terminal multiboot2 efi_gop efi_uga' \
    --output='$WSTAGE/EFI/BOOT/BOOTX64.EFI' \
    '/boot/grub/grub.cfg=$WCFG'
mcopy -i '$WESP' -s EFI ::
mcopy -i '$WESP' -s boot ::
mdir -i '$WESP' -/ :: | grep -E 'BOOTX64|koru.elf|cpio|elf' || true
# GPT wrap: ESP image lands at LBA 2048 (1MiB align); sgdisk writes
# primary+backup tables for the final disk size.
ESP_SEC=\$(( \$(stat -c%s '$WESP') / 512 ))
ESP_MIB=\$(( (ESP_SEC + 2047) / 2048 ))
TAIL_MB=8
DISK_MB=\$(( 1 + ESP_MIB + TAIL_MB ))
dd if=/dev/zero of='$WDISK' bs=1M count=\$DISK_MB
sgdisk -Z '$WDISK' >/dev/null
sgdisk -n1:2048:+\${ESP_SEC} -t1:EF00 -c1:KORU-ESP '$WDISK' >/dev/null
dd if='$WESP' of='$WDISK' bs=512 seek=2048 conv=notrunc
sgdisk -p '$WDISK'
" > "$WORK/wsl.build" 2>&1 || {
    echo "build-usb: WSL image build failed"; tail -15 "$WORK/wsl.build"; exit 1;
}

echo "build-usb: $OUT written — raw GPT disk, ESP=FAT32, removable BOOTX64.EFI"
echo "  QEMU: -drive if=pflash,format=raw,readonly=on,file=<OVMF code.fd> -drive file=$OUT,format=raw,if=none,id=stick -device usb-storage,drive=stick -serial stdio -display none"
echo "  real: dd if=$OUT of=/dev/sdX bs=4M && sync   (verify the stick first)"
