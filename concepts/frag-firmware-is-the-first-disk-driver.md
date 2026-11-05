---
type: belief
id: frag-firmware-is-the-first-disk-driver
provenance: koru-os native session — build-usb ESP rung, 2026-11
ts: 2026-11-05
tags: [native, boot, uefi, grub, esp, fat32, storage, drivers]
---

**Boot media and runtime storage are different problems, and the
firmware is allowed to be the first disk driver.** The flash-stick
artifact is a GPT disk whose FAT32 ESP carries GRUB-EFI plus
`boot/koru.elf` and `module2` payloads — and *nobody in koru-os reads
it*. OVMF firmware reads the GPT and FAT32 to load `BOOTX64.EFI`;
GRUB reads the ESP again to load kernel and modules; the kernel sees
only RAM (mb2 tags, pmm-reserved pages). The usb-esp gate proves the
whole chain with the stick attached as QEMU usb-storage: BdsDxe →
GRUB-EFI → mb2 → cpio module → initramfs view → child exec, status 0.

The ruling this encodes: **a system may boot and run userland on
media it cannot itself read.** Boot-time consumers — firmware,
bootloader — are permitted to be somebody else's drivers. The cost is
stated honestly: nothing persists, nothing can be updated or written
post-boot, and every byte of "storage" is loader-brokered RAM. The
xHCI/NVMe driver rung is therefore *not* on the critical path to
first real-hardware boot — it is on the critical path to persistence,
which is a different milestone. An expert would reject claiming this
as "storage support": it is bootstrapping, and the day a program needs
to write a file that survives reboot, the driver rung comes due.
