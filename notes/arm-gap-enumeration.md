# Arm-gap enumeration: `realize gen --arm koru-native`

Evidence class: M (generated on the Windows box, 2026-10-21; koru-os @ post-e46c728)

## Method

The row table is the contract; an arm's binding set is what it can serve. Running
`realize gen --arm <id>` for an arm that has no bindings yet is therefore not an
error path — it is the enumeration of the provider gap for that arm. Every
`refused:` line is one provider a standalone substrate must supply, produced by
the gate rather than hand-listed. Running it over the real boot programs
(`koru/*/tests/boot_*.k`) grows the table with the measured row catalog.

## Grown table (five boot programs)

| program | refusals | interfaces demanded |
| --- | --- | --- |
| `boot_ext2.k` | 6 | runtime, print, `koruos/ext2` {mount,create,verify,unmount} |
| `boot_nid.k` | 9 | runtime, print, `koruos/nid` {open,close,resolve,call,release,probe,retarget} |
| `boot_slice.k` | 14 | runtime, print, `koruos/slice` {census,load,resolve,unbind,close,reserve,seal,abandon,grant,start,wait,reap} |
| `boot_spawn.k` | 14 | runtime, print, `koruos/spawn` {census,authority,fork,reserve,abandon,seal,start,wait,reap,grant,revoke,authority-of} |
| `boot_silo.k` | 12 | runtime, print, `koruos/silo` {open,mint,bind,release,stats,close,call,tamper,discard,restart} |

Every module tor refuses individually; the union is five provider families plus
the runtime and console.

## What the standalone arm must provide (union, from the rows' resource columns)

| provider family | needed by | primitive demand (from row `resources`) |
| --- | --- | --- |
| runtime | all | heap allocator contract (`posix_memalign`/`free` today) + stack discipline |
| console | print, nid, spawn | character sink (today `fputs` on the Unikraft console / host-libc) |
| entropy | silo | `rdrand` or equivalent |
| clock | slice, nid, spawn | monotonic clock (today `ukplat_monotonic_clock`) |
| debug view | slice | `isa-debugcon` port 0x402 — QEMU-only even on linuxu; a native arm needs its own debug channel |
| address-space seam | spawn | the M-SPAWN-MMU page-table seam — the one provider that is *native* in spirit already (CR3 derivation is closer to ring-0 than to ukplat) |
| blk transport | ext2 | `uk_blkdev` queue ops over virtio-blk/PCI — native arm needs `blk.*` rows (virtio first, then NVMe/AHCI) |

Ordering by dependency: runtime+console first (everything reports through them),
then entropy+clock (silo/nid/slice are pure computations once they can allocate,
read a clock, and print), the spawn seam (it is the OS's own ring-0 work), and
blk last (first real device driver).

## What the enumeration already caught

- `koruos/ext2` had **no row at all** — it refused on every arm, including
  unikraft (`missing=realize row offered=none`). Fixed: the row now derives
  `CONFIG_LIBUKBLKDEV/LIBVIRTIO_BLK/LIBVIRTIO_PCI/LIBVIRTIO_BUS` (the M2 author
  lines, promoted to derived); it keeps no linuxu binding — virtio-pci is a
  KVM-plat device. This is the enumeration's intended use: it surfaces *catalog*
  gaps, not just arm gaps.
- `koruos/slice` has no linuxu binding: `isa-debugcon` is a QEMU port device;
  `outb` in linuxu userspace traps. First honest per-arm gap in the catalog.

## Semantics (fixed in this slice)

- A used interface whose row exists but has no binding for the selected arm is a
  `missing=binding for arm (row serves: …)` refusal — including `std.io:print`.
  The pre-refactor `std, pure` escape applies only to std modules with *no row*
  (pure codegen, no arm mechanism).
- `koru.runtime` is the always-on row; on an arm it does not serve it refuses
  first, because every program needs it.
- Author kconfig lines identical to a derived line are deduped in the Kraftfile
  (still reported as `override:` in table 3).
