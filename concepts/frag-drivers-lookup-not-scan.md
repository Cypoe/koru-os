---
type: belief
id: frag-drivers-lookup-not-scan
provenance: koru-os native session — pci-enum rung, 2026-10
ts: 2026-10-26
tags: [native, pci, drivers, substrate, contract]
---

Config space has **one owner**. Before pci.zig, two providers each
open-coded CF8/CFC type-1 cycles and walked the bus privately —
fb.zig scanning for class 0x03, virtio.zig scanning for 1af4:1001.
The duplication was the tell: **enumeration is a substrate service,
and a driver that rescans the bus is a bug shaped like a feature.**

The substrate's product is a *table*, populated once at boot:
`{bdf, vendor/device, class/subclass/progif, raw BARs, irq line/pin,
capability-list head}` — multifunction devices discovered via
header-type bit 7 (the PIIX3 IDE and ACPI funcs exist because 00:01.0
said they might), PCI-PCI bridges recursed by secondary bus number
behind a visited bitmap (a looped topology cannot spin the scan),
64-bit BARs merged into their pair.

Drivers then **attach by lookup, never by probe**: `find(vendor,
device)` or `findClass(class, subclass)` returns a table row; the
driver claims its BAR and IRQ through the shared accessors and
enables exactly the command bits it needs. Absent hardware is a
null lookup with the whole table in the serial dump — not a scan
that "didn't find it" and can't say what it skipped. The capability
walk (`capFind`) is part of the same contract: MSI/MSI-X/vendor
caps are *discovered* here, so negotiation material is visible
before any driver commits to a transport.

Ordering ruling, learned by oracle: enumeration runs **before sti**.
The first gate attempt had init after interrupts armed — an IRQ
print landed mid-line inside `caps=`, and a green mechanism
produced unsplittable evidence. Discover the hardware, then arm
the interrupts; a serial line torn by an IRQ is noise, not data.

Transports are **silos over the same table**, not one provider with
a personality flag. virtio-blk (legacy/transitional: port I/O
registers, INTx) lives in virtio.zig; modern virtio-pci (MMIO
common-config windows, VERSION_1 negotiation, split rings over
device-written MSI-X vectors) lives in virtiopci.zig; virtio-gpu
consumes the modern transport in gpu.zig. They share the
enumeration table and nothing else — a device picks its transport
by what its capability chain carries, and the provider family
refuses by name when the caps aren't there.

Capability iteration matters as much as lookup: modern virtio
devices carry *multiple* same-id vendor caps (1af4:1050 walks
`11,09,09,09,09,09`), so `capNext` iterates and `capFind`-only
code would see one fifth of the negotiation material. MSI-X is
now programmed, not just walked: `msixTable` locates the
BAR+offset window through the cap, `msixSetEntry` writes the
vector into table entry 0, `msixEnable` sets enable+INTx-disable
atomically — and the gate counts deliveries (`vgpu: cmds=6
msix=6`, LAPIC-EOI'd, never PIC-routed).

Honest bounds, named not silent: CF8/CFC only — ECAM/MMCONFIG via
ACPI MCFG is a different arm when PCIe-extended config space is
needed (MSI-X table discovery doesn't require it). BAR windows
are consumed through `mmio.map` — one shared identity-map owner,
because two modules installing `pdpt[3]` would evict each other's
mappings (the substrate lesson fb's private map taught).

Measured: `pci: 07 devices enumerated` on i440FX — host bridge,
PIIX3 multifunction (ISA+IDE+ACPI), std VGA, e1000, virtio-blk;
fb claims 1234:1111 by findClass(0x03,0x00), virtio-blk claims
1af4:1001 by find() and mounts ext2 through the table; virtio-gpu
claims 1af4:1050, negotiates VERSION_1, and presents real pixels
through MSI-X-delivered commands. Gates: boot 43/43, realize
13/13, hosted 43/43.
