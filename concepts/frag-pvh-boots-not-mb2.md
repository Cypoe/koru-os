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

The UEFI arm (`OVMF → GRUB-EFI → multiboot2`, same ISO) then measured the
deeper claim — **tag 8 is a contract, not a provider**: under EFI the same
tag carries a **GOP-programmed** framebuffer (GRUB needs `insmod efi_gop`
loaded *before* multiboot2 parses the request, else "no suitable video
mode" and the kernel falls back to BGA). Three fb source-of-truths now
exist behind one tag: VBE under BIOS-GRUB, GOP under EFI-GRUB, and the
absent tag under PVH. Two more firmware divergences surfaced the same
way: the RSDP came through mb2 tag 14 (no BIOS window exists under EFI)
at an address inside the mbi, and FADT decoded `pm1a=b004` where SeaBIOS
says `0604` — the decode-don't-hardcode ruling verified against a second
real firmware.

One bug the arm exposed, worth its own line: `fromMbi` printed
`backend=mb2` on tag *presence* while `adopt`'s `mmio.map` had already
refused — the serial claimed a backend that could not exist. A claimed
backend must follow the map landing, not the tag arriving; both `adopt`
sites now refuse by name. The same arm dissolved mmio's "one spare pd"
bound — the comment said a second window "needs the frame allocator's
page-table story; this is deliberately not it", and the allocator had
since landed, so windows now mint pds on demand. Deliberate bounds are
re-checkable obligations, not furniture.

Consequence held: any future "the loader should have told us" reasoning must
first ask *which* loader protocol fired — detected by the head word, not
assumed — and *which* firmware answered, since the same tag is a different
provider under EFI.
