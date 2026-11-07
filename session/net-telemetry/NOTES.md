# net-telemetry — UDP diagnostic channel for ThinkPad native kernel

Commission: `session/net-telemetry-BRIEF.md`. TX-only Ethernet+IPv4+UDP
stage-marker telemetry so boot progress is readable while the display is
dead (i915 bring-up blinds every local output). Milestones N0→N3.

## Status: N0–N3 PROVEN IN QEMU — ISO SHIPPED, HW FLASH PENDING

- Driver: `koru/native/e1000e.zig` — TX-only port of iPXE
  `src/drivers/net/intel.c` (ref copy `session/net-telemetry/ref/`).
  I219 family (all ~40 PCI IDs, NO_PHY_RST|RST_HANG flags) + 82574L +
  82540EM so QEMU exercises the same path. PCI probe → BAR0 MMIO map →
  reset → MAC (RAL0/RAH0 autoload, EERD fallback) → 32-desc TX ring,
  polled DD, no RX/no IRQs. All waits bounded; failure = serial say +
  boot continues.
- Net: `koru/native/net.zig` — broadcast-MAC Ethernet carrying
  UNICAST-IP UDP (TX-only can't ARP-resolve; only the IP owner accepts
  at L3). ARP who-has emitted at init as wire proof. Real IPv4+UDP
  checksums. Config: src 192.168.1.222 → dst 192.168.1.5 udp/47820,
  payload `KORU <stage>` (coordinated w/ t1).
- Integration: `boot.zig` kmain calls `net.init()` right after
  `pmm.init` (before anything that can die blind) + `net.mark(...)` at
  fb-init/shell/comp/aspace/prog stages. `pci.init` made idempotent.
- Build: `KORUC=~/src/koru-cypoe/zig-out/bin/koruc
  KORU_STDLIB=~/src/koru-cypoe/koru_std ZIG=/opt/homebrew/bin/zig
  bash scripts/build-native.sh <prog.k> <elf>` (macOS recipe per m0 baton)
- ISO: isotree → `docker koruos-amd64-img grub-mkrescue` → MBR patch
  (0x1be=0x83, entry0 LBA=0x10) → `session/net-telemetry/dist/`.

## QEMU evidence (oracle = Mac listener, pid-bound udp/47820)

`listener.log` received, twice (kernel -kernel path AND -cdrom ISO path):
```
KORU N2 udp telemetry live
KORU fb-init
KORU shell
```
Serial shows `e1000e: tx ring armed — link=true mac=52:54:00:12:34:56`
(QEMU 82540EM) and `net: N1 arp who-has on wire`. ISO boot chain proven:
GRUB multiboot2 → kmain → net.init → markers → shell.

## Bugs found en route (both @intCast-vs-@truncate, ReleaseSafe ud2)

1. e1000e fetchMac: `@intCast(u32→u8)` on RAL0/RAH0 bytes → panic.
2. net put16/put32: `@intCast(v)` for low byte → panic on any v>255
   (ethertype 0x0806 killed it). Diagnosed via QEMU `-d int` (#UD→#GP→#DF,
   no IDT on console path) + objdump of the ud2 site + rodata panic str.

## HW flash instructions

Etcher `session/net-telemetry/dist/koru-net-telemetry-n3-20261107-1329.iso`
to SD → T590 boots GRUB → kernel → net.init probes PCI for I219-LM.
Listener MUST be running (`python3 session/net-telemetry/listen.py 47820`).
Expected markers in order: N2 udp telemetry live → fb-init → shell
(consoleMode path). Last marker = furthest stage reached.
If `net: NIC init failed` on serial — I219 PCI ID not in table; serial
dump names it, add to DEV_IDS.

## Honest bounds / next

- TX-only: no ARP resolution, no RX, no DHCP — static config only.
  Broadcast-MAC+unicast-IP is deliberate (documented above).
- I219 PHY path is iPXE-faithful but unverified on real silicon — first
  flash is the oracle; link=false or missing markers name the stage.
- QEMU tested 82540EM; `-device e1000e` (82574L) is the closer model —
  untested this session.
- RX ring / ARP cache / DHCP are the obvious N+1 when telemetry earns it.
