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

## Landed: the first provider (`koruos/native`, post-0d49358)

`koru/native/` is the first `koru-native` provider family: `runtime.zig`
compiles freestanding (`zig build-obj -target x86_64-freestanding-none`)
and carries the exact contract the emitted backend declares — the
flow-prologue heap (`posix_memalign`/`free` over a 4 MiB bump region;
`free` is a no-op until the spawn seam lands) and `__kout`'s console
(`fputs`/`stdout`/`stderr` routed to COM1 115200 8N1 — real hardware,
QEMU `-serial`, and a debug board alike; deliberately not isa-debugcon).

Its `index.kz` declares two `koruos/realize:row` blocks whose `iface`
targets `koru.runtime` and `std.io:print` — bindings merged onto the
builtin rows with `koruos.native` provenance, mechanism `native-runtime`,
payload `deltas=src:koru/native/runtime.zig`. Measured:

- program importing `koruos/native` → `manifest-koru-native.txt` written,
  2 bound (`bind: koru.runtime -> native-runtime`, `bind: std.io:print
  -> native-runtime`), no refusals;
- program *not* importing it → both interfaces still refuse. The provider
  is opt-in: a substrate is a lift you import, not ambient magic.

Second wave (same provider, more contracts): `runtime.zig` grew
`ukplat_monotonic_clock` — TSC calibrated once against the i8253 PIT
channel 2 (1.193182 MHz, ~10 ms once, no guessed frequency). Measured on
the real boot programs (`import koruos/native` added — opt-in holds):

- `boot_silo` → 3 bound, manifest written (entropy is the `rdrand`
  instruction in the lift itself — `needs:cpu rdrand` rides the bind
  deltas);
- `boot_nid` → 3 bound (clock + heap + console);
- `boot_slice` → 3 bound (the debug view stays `isa-debugcon` — QEMU
  `-debugcon` only; writes silently drop on real hw, so a native debug
  channel remains an open provider);
- `boot_spawn` → 3 bound (12 tors), after a corrected read. The earlier
  "no process substrate beneath, refuse" was wrong *at the lift's
  declared rung*: `koruos/spawn` is rung 0/1 by design — entry-function
  children run to completion inside `start`, one address space, the
  bag enforced at the seam. Its whole extern surface is
  `malloc`/`free`/`ukplat_monotonic_clock`/`stdout`/`fputs` — already
  served. The refusals were a missing binding, not a missing substrate;
  the `koru-native` bind now exists with the caveat riding deltas —
  provisional, MMU/IOMMU isolation caps eventual. What genuinely remains
  open is the *MMU-isolated* spawn — real address-space separation and
  ELF children — a different binding family (M-SPAWN-MMU), not a blocker
  for this rung.

## Next items (ordered)

1. ~~**Boot entry**~~ — **DONE, measured.** `koru/native/boot.zig` carries
   the multiboot2 header + PVH note (both loaders land in 32-bit protected
   mode; QEMU `-kernel` on ELF64 uses the PVH path), a 32→64 trampoline
   (identity map 0–6 MiB, PAE/LME/PG, `CR4.OSFXSR|OSXMMEXCPT` + `CR0.MP`
   for SSE — the emitted memset needs xmm), `link.ld` (`KEEP` the header
   inside the first 32 KiB), 512 KiB stack, `kmain → prog.main()`. Gate:
   `scripts/check-boot.sh` boots `native/tests/boot_hello.k` under QEMU
   and asserts `KORU NATIVE BOOT OK` on serial — measured 2026-10-21.
   `native-runtime` now owns the `_start` boundary, not just symbols.
   Known honest limits: identity-mapped, 6 MiB window, bump heap,
   multiboot info ignored (no cmdline/modules yet).
2. **blk transport** — **virtio done (legacy I/O-port), measured
   2026-10-21.** `koru/native/virtio.zig` serves the same `uk_blkdev_*`
   externs the ext2 lift consumes (transitional PCI 0x1AF4:0x1001, BAR0
   I/O window, one synchronous queue, polled used ring). `runtime.zig`
   adds `malloc`/`memalign`/`_uk_alloc_head`; ext2's row gained a
   `koru-native → native-runtime` bind. Gate: `check-boot.sh` boots
   `native/tests/boot_ext2.k` on a host-made ext2 image — full
   mount→create→verify→unmount prints `EXT2N COMPLETE`. Honest limits:
   transitional devices only (no modern virtio capability negotiation),
   polling not interrupts, single queue, QEMU device needs
   `disable-modern=on`. **Open:** NVMe/AHCI and modern virtio-pci are
   still missing families.
3. **Real debug channel** — `isa-debugcon` port 0x402 is QEMU-only and
   silently drops on real hardware; needed for bare-metal bring-up past
   serial alone.
4. **MMU-isolated spawn (rung 2+)** — real address spaces + ELF children.
   MMU/IOMMU capabilities are eventual on `native-runtime` (own
   substrate, not host-supplied like `kconfig`/`host-libc`); the
   provisional binds stay rung-honest until this family exists.
   **Sub-ladder in flight, two capabilities measured 2026-10-21:**
   `koru/native/aspace.zig` clones the boot tables into a second CR3
   domain and proves on serial that VA 0x800000 resolves to different
   physical pages per space (`ASPACE A=aaaa B=bbbb DISTINCT`, pinned by
   `check-boot.sh`). `koru/native/user.zig` then completes the first
   ring3 descent: a child CR3 with user (U/S) pages at VA 0x800000 —
   U/S required at *every* walk level, kernel leaves stay ring0-only —
   `iretq` into CPL=3 (user GDT entries + TSS + a 256-entry IDT added
   by the module), the child writes a marker byte into its own page
   and raises `int 0x80` — the embryonic syscall seam — which lands on
   TSS.rsp0 and reports on serial (`RING3 OK`, pinned). Measured bug:
   `pd[4]` covers 8–10 MiB, not 4 — the first user window faulted on a
   VA that walked the wrong slot. **ELF64 + return-able seam landed the
   same day:** the child is now a real ELF64 (embedded in the kernel
   image; ext2 read-by-path is a later rung) — parsed, PT_LOAD pages
   mapped at `p_vaddr`, entered at `e_entry`. The seam is a full trap
   frame (all GP regs), dispatch on `rax`: `write(fd,buf,len)` to
   serial returns its length and the child *continues* — the
   iretq-back direction is exercised — and `exit(code)` reports on
   serial then halts. Evidence pinned: `elf child says hi` +
   `ELF CHILD EXIT ...2a`. Remaining rungs: ELF from ext2 (read-by-path
   or a loader fs), the seam grown to a real ABI (SYSCALL/SYSRET, a
   rights-bag check per call, exit reaping to a parent), then the
   rung-2 spawn provider family that binds all of it.

## Semantics (fixed in this slice)

- A used interface whose row exists but has no binding for the selected arm is a
  `missing=binding for arm (row serves: …)` refusal — including `std.io:print`.
  The pre-refactor `std, pure` escape applies only to std modules with *no row*
  (pure codegen, no arm mechanism).
- `koru.runtime` is the always-on row; on an arm it does not serve it refuses
  first, because every program needs it.
- Author kconfig lines identical to a derived line are deduped in the Kraftfile
  (still reported as `override:` in table 3).
