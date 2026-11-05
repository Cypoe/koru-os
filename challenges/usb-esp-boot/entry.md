---
name: usb-esp-boot
iface: koruos/boot.esp
arms: [koru-native]
lane: oracle
needs: [fs-initramfs]
accept: gate row usb-esp — OVMF->USB-storage->GPT->FAT32->GRUB-EFI->mb2
tier: qemu
status: landed
evidence: M
peer: —
provenance: original — build-usb.sh GPT/FAT32 ESP + grub-mkstandalone
---

# usb-esp-boot

The dd-able artifact: a raw GPT disk whose FAT32 ESP carries a
standalone GRUB-EFI (`\EFI\BOOT\BOOTX64.EFI`, modules+cfg embedded),
`boot/koru.elf`, and `module2` payloads. Firmware does the disk reads —
nobody in koru-os touches the stick.

## Acceptance

Gate row `usb-esp`: OVMF pflash + qemu-xhci usb-storage — BdsDxe boots
the USB harddrive, GRUB-EFI loads kernel+module, initramfs view serves
`/bin/fsread`, status=0.

## Notes

- Secure Boot unsigned — BOOTX64.EFI is not a signed shim path (hw-tier
  caveat, see hw-tier-validation).
- frag-firmware-is-the-first-disk-driver: boot media and runtime
  storage are different problems.
