#!/usr/bin/env bash
# build-iso.sh <prog.k> [out.iso] [payload.elf] — a bootable El Torito ISO:
# the koru ELF behind GRUB's BIOS multiboot2 loader. SeaBIOS -> GRUB -> mb2 is the
# real-loader path QEMU -kernel/PVH never exercises: the e820 walk runs
# mb2 tag 6, the loader programs and hands a linear fb via tag 8 (PVH can
# never mint it), and ACPI resolves via loader tag / EBDA scan.
# Needs WSL grub-mkrescue + xorriso (Ubuntu: xorriso grub-pc-bin mtools).
#
# payload.elf, when given, is staged at /boot/<base> and loaded with
# GRUB's `module` — it reaches the kernel as an mb2 tag-3 module (the
# same transport a flash stick's ESP payload will use).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROG="${1:?usage: build-iso.sh <prog.k> [out.iso] [payload.elf]}"
OUT="${2:-koru.iso}"
PAYLOAD="${3:-}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/iso/boot/grub"
bash "$ROOT/scripts/build-native.sh" "$PROG" "$WORK/iso/boot/koru.elf" \
    > "$WORK/native.build" 2>&1 || {
    echo "build-iso: kernel build failed"; tail -10 "$WORK/native.build"; exit 1;
}

if [ -n "$PAYLOAD" ]; then
    cp "$PAYLOAD" "$WORK/iso/boot/$(basename "$PAYLOAD")"
fi

# GRUB on COM1 — the loader's own banner is part of the boot evidence:
# "GRUB: multiboot2 ..." on serial proves a loader ran, not -kernel.
cat > "$WORK/iso/boot/grub/grub.cfg" <<'CFG'
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
    echo "GRUB: multiboot2 /boot/koru.elf"
    insmod multiboot2
    multiboot2 /boot/koru.elf
CFG
# `module2` is GRUB's multiboot2 module command — `module` is the mb1
# spelling and refuses "you need to load the kernel first" under mb2.
# The tag's string field is a CMDLINE (args after the file), not the
# path — the basename is passed so the kernel can name the module.
if [ -n "$PAYLOAD" ]; then
    echo "    module2 /boot/$(basename "$PAYLOAD") $(basename "$PAYLOAD")" >> "$WORK/iso/boot/grub/grub.cfg"
fi
cat >> "$WORK/iso/boot/grub/grub.cfg" <<'CFG'
    boot
}
CFG

WISO="$(wsl -e wslpath -u "$(cygpath -w "$WORK/iso")")"
WOUT="$(wsl -e wslpath -u "$(cygpath -w "$OUT")")"
# MSYS_NO_PATHCONV: /mnt/c/... args must reach wsl.exe untouched — Git Bash
# rewrites them to C:/Program Files/Git/mnt/... otherwise.
MSYS_NO_PATHCONV=1 wsl -e grub-mkrescue -o "$WOUT" "$WISO" > "$WORK/mkrescue.log" 2>&1 || {
    echo "build-iso: grub-mkrescue failed"; tail -10 "$WORK/mkrescue.log"; exit 1;
}
echo "build-iso: $OUT written — boot with: qemu-system-x86_64 -cdrom $OUT -boot d -serial stdio -display none"
