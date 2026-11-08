# Koru OS i915 bring-up — M1 kernel boot-crash on real hardware (fresh-eyes brief)

## TL;DR for the investigator

A bare-metal Zig kernel for the Koru OS project boots fine on QEMU and on
one known-good ISO on real hardware, but **any kernel whose loaded image is
~32KB+ larger triple-faults on real hardware before reaching the NIC** —
panel flickers twice, returns to the bootloader, zero debug output. The bug
is **binary size/layout, not source code** (proven by byte-identical controls).
Find why a larger kernel image crashes on real silicon and propose a fix.

## Hardware / environment

- **Machine**: ThinkPad T590, Intel Kaby Lake-R UHD 630 iGPU (PCI dev `0x00003ea0`), eDP panel.
- **Boot**: ISO → GRUB (multiboot2) → kernel ELF `boot/koru.elf` → `_start` asm → long mode → `kmain`.
- **Observability**: UDP telemetry to a Mac listener at `192.168.99.1:47820` (ThinkPad `192.168.99.2`). Only works AFTER `net.init` (e1000e NIC). Pre-NIC window is blind except the framebuffer.
- **Kernel**: Zig freestanding, entry `0x100050`, loads at `0x100000`. `_start` sets up long-mode page tables inside `.bss` (identity map 0–32MiB), 512KB stack in `.bss`. `pmm.init` parses the multiboot2 memory map.

## What WORKS (proven on this hardware)

- **M0 i915 static scanout** — full modeset: power wells → DPLL/CDCLK → AUX/DPCD → DP link-train (CR+EQ pass) → plane scanout at 1080p60. Panel shows checkerboard+text. ISO `koru-i915-net-20261107-1949.iso` boots to shell+heartbeat on the T590.
- **UDP telemetry** — every console line + `KORU` stage markers stream to the listener.

## The bug (M1 dumb-KMS milestone)

Branch `native/m1-dumb-kms` in worktree `/Users/larsde/src/koru-os-m1` adds a
KMS object model + dumb-buffer path (`koru/native/i915/kms.zig`) plus an
`earlyfb` boot oracle. **Every M1 ISO crashes on real HW pre-NIC.** QEMU `-cdrom`
boots all of them fine to shell.

### Bisect evidence (all verified)

| ISO | kernel | `_end` | real-HW result |
|---|---|---|---|
| known-good (i915-net-1949 / srcbase / nokms) | merge-base | `0x6C9918` | **boots** |
| sizepad32 | good + 32KB benign `.rodata` | `0x6D1918` | **crashes** |
| sizepad64 / M1-full | M1 code | `0x6D9918` | **crashes** |

- ELF headers **structurally identical**: entry `0x100050`, mb2 magic `d65052e8` at file off `0x1020` (len=48), 7 program headers, same segment layout — only sizes differ.
- `boot.zig` and `faults.zig` **byte-identical** to the working build (`git diff fc509df` empty).
- Reverting `kms.zig` → kernel **byte-identical** to known-good across all LOAD segs.
- `earlyfb` fully removed → still crashes.
- Build recipe (`zig build-exe` flags + module list) **identical** to proven pipeline; proven-pipeline rebuild is byte-identical.
- **Conclusion: pure binary size/layout. `kms.zig` is innocent — a 32KB pad of dead `.rodata` crashes identically.**

### Threshold

Working `_end=0x6C9918`; crashing at `_end=0x6D1918` (32KB pad) — so headroom is
**<32KB**. Very tight → suggests a *specific object* near `~0x6C9000–0x6D1000`
gets overlapped, not a generic "too big" limit.

## Leading hypothesis (unverified)

The kernel's last `PT_LOAD` has `memsz≈0x56f918` (~5.7MB) — a huge `.bss`
(fb buffers, page tables, heap). The kernel zero-fills `.bss` at boot up to
`_end`. **If `.bss` now extends into physical memory where GRUB placed the
multiboot2 info struct / modules / LFB**, the BSS-init zeroing tramples them →
crash before NIC, before any output, triple-fault-reset to GRUB. QEMU's GRUB
places these differently → tolerated.

To verify: find where GRUB puts the mb2 info struct + modules (the kernel
receives the info pointer in `ebx` at `_start`; mb2 tags describe module
locations), get their physical addresses, and check whether the kernel's
`.bss`/`_end` range overlaps them at the crashing sizes but not the working one.

Alternative hypotheses to rule out:
- GRUB-side: kernel footprint shifts where GRUB places modules/info/LFB into a bad spot.
- A real-HW memory-map edge (e.g., kernel image now crosses into a region the
  firmware/GRUB reserves) that QEMU's map lacks.
- `.bss`/`_end` crossing a page-table or identity-map boundary in `_start`.

## Key files / paths

- Worktree: `/Users/larsde/src/koru-os-m1` (branch `native/m1-dumb-kms`)
- Kernel native sources: `koru/native/` — `boot.zig` (`_start`, `kmain`), `earlyfb.zig`, `i915/kms.zig`, `fb.zig`, `pmm.zig`, `mmio.zig`, `faults.zig`, `shell.zig`, `text.zig`, `link.ld`
- Proven build recipe: `/Users/larsde/src/koru-os-merge/scripts/build-native.sh` + `check-boot.sh`; session notes `/Users/larsde/src/koru-os-thinkpad/session/m0-i915/NOTES.md`
- Reference display init: `/Users/larsde/src/koru-desktop/session/m6-i915/libgfxinit/` and `RESULT.md`
- ISOs: `/Users/larsde/src/koru-os-m1/session/m1-dumb-kms/dist/` (all timestamped); known-good `/Users/larsde/src/koru-os-merge/session/net-telemetry/dist/koru-i915-net-20261107-1949.iso`
- ELF artifacts for diffing: `m1full.elf`, `m1nokms.elf`, `m1prov.elf`, `m1srcbase.elf`, `m1.elf` under `session/m1-dumb-kms/`

## What we need back

1. **Root cause** of the size/layout boot crash on real hardware — with the
   specific address/mechanism, not a guess.
2. **A concrete fix** — e.g., relocate the colliding structure, shrink/move
   `.bss`, change load address, adjust GRUB module placement, or whatever the
   evidence supports.
3. If the honest answer is "this needs on-hardware register/memory-map
   visibility we don't have," say so and propose the cheapest observable that
   would crack it (the pre-NIC window is the hard part — no serial, LEDs dead,
   only framebuffer which is itself crash-prone).

## Constraints / gotchas

- No serial console; ThinkPad caps/Num LEDs physically don't respond (dead EC path).
- The framebuffer is the only pre-NIC display channel but drawing to it has itself crashed.
- QEMU `-cdrom` boots everything — it is NOT a valid oracle for this bug; only real HW is.
- Dead keyboard keys `5`,`6` — shell commands must be alphabetic.
- Don't propose fallbacks; the fix must address the real mechanism.
