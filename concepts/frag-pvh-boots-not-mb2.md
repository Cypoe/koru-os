---
type: belief
id: frag-pvh-boots-not-mb2
provenance: koru-os native session — pmm rung, 2026-10
ts: 2026-10-24
tags: [boot, oracle-lesson]
---

QEMU `-kernel` boots our image through **PVH**, not multiboot2: the
`.note.Xen` in `koru/native/boot.zig`'s header makes the loader take the Xen
path, and `EBX` arrives as a `hvm_start_info` pointer (`head =
0x336ec578` = `XEN_HVM_START_MAGIC`), not an mb2 info block.

Held-belief repudiated: "the mb2 framebuffer request tag failed because of a
loader quirk" — no tag walk was ever *possible* under QEMU `-kernel`; the
only mb2 path is GRUB. This is why BGA register-programming (not the fb tag)
is the real fb source on QEMU, and why `pmm.init` reads the PVH `memmap_paddr`
table first with mb2 tag 6 kept for GRUB.

The GRUB path is now measured, not designed-for (`build-iso.sh` →
El Torito ISO, SeaBIOS → GRUB → `multiboot2 /boot/koru.elf`). What the
first real mb2 boot taught:

- **The fb request tag works under a real loader.** The header's
  1024x768x32 request — dead text under PVH — made GRUB program VBE and
  mint tag 8; `fb.init` reports `backend=mb2` and the compositor runs
  on loader-programmed memory. Three fb backends exist now and the
  *source of truth differs per boot protocol*: loader tag under mb2,
  virtio scanout under -device, BGA registers as the fallback.
- **The RSDP moves.** PVH finds it in the BIOS window at `0xf52e0`;
  GRUB hands an mb2 tag copy at `0x766fb0`. Same table, different
  carrier — consumers must never cache "where firmware lives".
- **The e820 walk is real.** `pmm` reads tag 6 (127 MiB usable) — the
  code path written blind got its first walk under a loader.

Consequence held: any future "the loader should have told us" reasoning must
first ask *which* loader protocol fired — detected by the head word, not
assumed.
