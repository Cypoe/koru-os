---
type: belief
id: frag-power-door-decodes-firmware
provenance: koru-os native session — MADT/FADT + powerctl rung, 2026-10
ts: 2026-10-30
tags: [native, acpi, power, contract, substrate]
---

Power-state transitions are **one named door with decoded payloads**, not
scattered `outb` folklore. `koruos_powerctl(cmd)` takes an intent verb
(1 = reboot, 5 = S5 off) and the door owns the routing: S5 rides the
ACPI PM1a control port, reboot rides the 8042's reset pulse. The caller
names intent; the door picks the provider — two mechanisms behind one
verb-dispatch, the same doctrine as the two interrupt doors.

The decisive ruling: **firmware decodes the bits; the kernel never
hardcodes them**. The SLP_TYPa value shifted into PM1a_CNT is not the
`0x2000`-style constant a tutorial writes — it is read out of the DSDT's
`_S5` AML package (`(byte, byte)` — typa/typb), and the control port
itself is FADT's `PM1a_CNT_BLK` field, both reached through `findTable`
on the walked SDT directory. SeaBIOS answers `typa=0`, which is why the
canonical QEMU shutdown write is `0x0000|SLP_EN`, not the `0x2000` a
hardcoded port-culture would emit. A platform where `_S5` decodes to a
different sleep type is handled by the same code — the decode IS the
portability layer. A malformed or absent `_S5` makes the door refuse by
name; there is no fallback constant.

The evidence shape matters: for poweroff and reboot the serial marker
alone cannot prove the door fired — a refused or mis-decoded write
*hangs*, and the marker prints anyway. The gate asserts the marker AND
that QEMU exits before `timeout` (rc≠124): a clean terminate IS the
payload landing. Reboot runs under `-no-reboot` so the 8042 pulse's
reset surfaces as a QEMU exit the same way.

The MADT payload behind `findTable("APIC")` is counted the same way —
lapic base from the header, enabled-cpu/ioapic/ISO counts walked per
entry type — the names SMP's AP-bringup consumes. Parse-once-at-boot
tables, consumers read counts, not re-scan.

Measured: `madt: lapic=fee00000 cpus=1(1en) ioapics=1 isos=5`,
`fadt: pm1a=604 dsdt@3fe0040 s5 typa=0 typb=0`, `powerctl-acpi` and
`powerctl-reboot` both rc=0 — the VM exited on each door. Gates:
boot 54/54.
