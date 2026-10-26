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

Honest bounds, named not silent: CF8/CFC only — ECAM/MMCONFIG via
ACPI MCFG is a different arm when PCIe-extended config space is
needed (MSI-X table discovery doesn't require it). The MSI-X cap
walk exists and measured (1af4:1001 → caps=11); *programming*
MSI-X waits for its first consumer — an unused vector table is an
unmeasurable claim. That's virtio-gpu's rung.

Measured: `pci: 07 devices enumerated` on i440FX — host bridge,
PIIX3 multifunction (ISA+IDE+ACPI), std VGA, e1000, virtio-blk;
fb claims 1234:1111 by findClass(0x03,0x00), virtio-blk claims
1af4:1001 by find() and mounts ext2 through the table. Gates:
boot 40/40, realize 13/13, hosted 43/43.
