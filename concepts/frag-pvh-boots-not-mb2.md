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

Consequence held: any future "the loader should have told us" reasoning must
first ask *which* loader protocol fired — detected by the head word, not
assumed.
