# net-telemetry — UDP diagnostic channel for ThinkPad native kernel

Commission: `session/net-telemetry-BRIEF.md`. TX-only Ethernet+IPv4+UDP
stage-marker telemetry so boot progress is readable while the display is
dead (i915 bring-up blinds every local output). Milestones N0→N3.

## Status: N0–N3 PROVEN IN QEMU — ISO SHIPPED, HW FLASH PENDING

Topology (updated 2026-11-07 ~14:00): direct P2P link, no router.
Mac en8 (USB GbE dongle) = 192.168.99.1/24 LIVE 1000baseT;
ThinkPad src = 192.168.99.2, dst udp/47820, static both ends.
Listener bound 0.0.0.0:47820 — receives on en8 (NOT en0/192.168.1.5).
Current ISO: `dist/koru-net-telemetry-send-20261107-1420.iso`
(supersedes diag-1407, frame-1420, p2p-1359, n3-1329 — do not flash
those).

## HW silence postmortem + diagnostics (2026-11-07 ~14:10)

First HW flash (p2p-1359): booted to shell, link light ON, ZERO UDP.
Serial diagnostics are invisible on the T590 (no serial port) — the fb
shell is the only oracle, which is why shell commands matter.

Init assumptions real silicon may violate, now instrumented:
1. **Link-up timing** — old code read STATUS.LU once ~100ms after
   ringSetup; PHY autoneg on a cold P2P link takes ~1-2s, so every boot
   marker likely fired into a dead link. FIXED: init now polls LU up to
   5s before markers; link state is also re-read live on every tx.
2. **BAR0 decode** — assumed MEM+BM command bits take effect; now
   readback (cmd=, st=, tctl=, ring bal/len/dh/dt) captured in Diag and
   emitted as `KORU diag ...` marker + shown by shell `net`.
3. **MAC source** — RAL0/RAH0 autoload vs EERD fallback now recorded
   (mac_src 1|2) in diag.
4. **TX completion** — new txProbe: synchronous DD-bit wait (200ms) —
   distinguishes "descriptor never completed" (ring/setup broken) from
   "completed but nothing on wire" (link/L2). Shell `udp` uses it.
5. **Ring alignment** — tx_descs/tx_bufs now page-aligned (iPXE erratum).

Shell commands added (fb console — the visible surface on HW):
- `net` — up/down, live link+STATUS reg, MAC, IPs, init stage, BAR/cmd/
  tctl/ring readbacks, TX sent/done/fail counters, last probe result.
- `udp <a.b.c.d> <port> <msg>` — arbitrary datagram + sync DD probe;
  prints "descriptor COMPLETED" vs "TX failed/timeout".

Diag marker example (QEMU-verified arriving at listener):
`KORU diag st=6 bar=febc0000 cmd=107 st=80080783 tctl=400fa bal=255000
len=200 dt=0 mac=52:54:00:12:34:56 msrc=1 link=1`

## HW round 2: TX completes on real I219, wire still silent (2026-11-07 ~14:30)

`udp` on the T590 reports "tx descriptor COMPLETED (dd)" — the TX ring,
descriptor format, and TDT path are PROVEN on real silicon. But Mac en8
Ipkts stayed flat — zero frames delivered to IP. Prime suspects now
L2/wire-level, not the stack: dst MAC not broadcast on the wire, bad
FCS, bad src MAC (receiver-side discard), or frames never reaching en8.

Eth-header audit result: construction is correct in source —
dst=ff:ff:ff:ff:ff:ff, src=RAL0/RAH0-or-EEPROM MAC, ethertype 0x0800 BE,
IPv4+UDP checksums computed (slirp delivered payloads, proving L3
parse). New `frame <ip> <port> <msg>` shell command hex-dumps the exact
built frame (no TX) for byte-for-byte verification on the T590.
New `send <msg>` payload-only command (fixed P2P path) for the flaky
keyboard. Desc-status polls now volatile.

HW debug recipe v2: flash send ISO → `net` (MAC + link + counters) →
`frame 192.168.99.1 47820 hi` (verify ff:ff:ff:ff:ff:ff / 0800 / proto
11 bytes on screen) → `send hello` (dd=ok expected) → meanwhile
`sudo tcpdump -i en8 -e -n` on the Mac: ARP who-has at boot is the L2
canary — if tcpdump sees ARP but not UDP, it's IP-layer; if nothing at
all, frames aren't reaching en8 (FCS/MAC/PHY).

HW debug recipe: flash diag ISO → at shell type `net` (shows exactly
what init did — stage<6 = where it stopped, st=ffffffff = dead BAR)
then `udp 192.168.99.1 47820 hello` (probe=ok + listener hit = TX path
works; probe=timeout = descriptor ring dead).

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
  checksums. Config: src 192.168.99.2 → dst 192.168.99.1 udp/47820,
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

`listener.log` received, three times (kernel -kernel path, -cdrom ISO
path, -cdrom P2P ISO path):
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

Etcher `session/net-telemetry/dist/koru-net-telemetry-p2p-20261107-1359.iso`
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

## Payload-only commands + checksum audit (2026-11-07 ~14:30)

Checksum audit: csum+buildUdpFrame replicated in Python — both IP and
UDP checksums validate to residue 0000; on-disk Zig matches line-for-
line. Algorithm is correct; divergence (if any) is Zig-emission vs
replica — `frame` dump on HW is the check. tcpdump showed the frame
arrives perfectly (real Intel MAC, broadcast, correct 5-tuple) but
listener never logs -> pre-socket drop. Need: `frame` hex output +
`sudo tcpdump -i en8 -e -n -v udp port 47820` (bad cksum flag names
ip vs udp) + optional `udp 192.168.99.255 47820 x` broadcast-IP test.

Commands now payload-only for the flaky keyboard: `send <msg>`,
`frame [msg]` (bare = canned probe), `net` arg-free. Full-arg
`udp <ip> <port> <msg>` kept as hidden debug variant.
Current ISO: dist/koru-net-telemetry-payload-20261107-1428.iso

## Checksum bug CONFIRMED on HW wire (2026-11-07 ~14:50)

tcpdump -XX on en8: frame arrives perfect (bcast MAC, real Intel MAC
00:2b:67:2d:f0:92, 192.168.99.2->192.168.99.1, 47821->47820, len 40/20,
'HELLO DEVIN!') BUT both checksums bad: IP field=0xf368 correct=0x3ae3,
UDP field=0x7675 correct=0xdc55. macOS drops pre-socket -> listener flat.

Analysis: Zig algorithm == Python replica == wire field values
(UDP 0x7675 exact match; IP 0xf368 = canonical+ID8). tcpdump's "correct"
matches NO ID 0-40 and NO single-byte mutation -> the bytes checksummed
differ from bytes transmitted in a multi-field way, OR wire bytes differ
from canonical reconstruction. Next data needed: full tcpdump -XX hex +
`frame` output (now prints computed ipcsum/udpcsum alongside hex dump).
ISO: dist/koru-net-telemetry-cksum-20261107-1447.iso

## UDP csum=0 expedient build (2026-11-07 ~15:10)

RFC 768: UDP checksum optional over IPv4 — zeroed on the wire as a
parallel expedient while the real bug is chased. last_udp_csum still
records the computed value so `frame` output supports A/B comparison.
ISO: dist/koru-net-telemetry-ucsum0-20261107-1507.iso (QEMU-verified,
markers arrive). Checksum-debug ISO kept: cksum-20261107-1447.

## Checksum EXONERATED + unicast/broadcast A/B ISO (2026-11-07 ~15:45)

Wire hex proved the frame is byte-for-byte canonical AND both checksums
VALID (IP f364, UDP 3e37, residue ffff) — the "bad checksum" was the
verifier's arithmetic, not the packet. macOS drops a VALID packet ->
non-checksum cause. Prime suspect: unicast-IP inside broadcast-MAC
filtered pre-IP-layer (fits tcpdump-sees-it + Ipkts-flat + listener-flat).

New ISO dist/koru-net-telemetry-ab-20261107-1541.iso:
- 'send <msg>'  = unicast dst-MAC (en8 c8:4d:44:27:22:c3) + unicast IP .99.1
- 'sendb <msg>' = broadcast MAC + broadcast IP .99.255 (standard bcast frame)
- 'udp <ip> <port> <msg>' = broadcast MAC + arbitrary IP (debug)
- boot markers now also unicast-MAC (EN8_MAC) — permanent telemetry path.
- 'frame'/'peekMsg' match 'send' (unicast). QEMU-verified dstmac=c84d442722c3.

## TELEMETRY LIVE ON HW + hardened ISO (2026-11-07 ~16:00)

CONFIRMED on real T590 I219-LM: listener caught 192.168.99.2:47821 boot
markers (diag/N2/fb-init/shell) + manual sends. ROOT CAUSE of the whole
silence saga: macOS drops unicast-IP inside broadcast-MAC frames before
IP-layer delivery — NOT a checksum bug (wire hex proved both checksums
valid, residue ffff). Fix = unicast dst-MAC c8:4d:44:27:22:c3 (en8).

ISO: dist/koru-net-telemetry-hb-20261107-1557.iso — heartbeat build.

## Protocol semantics (permanent diagnostic channel)

- TX-only UDP, fire-and-forget: no ACK, no retransmit, no RX path.
- Listener MUST be up before boot or early markers are lost
  (python3 session/net-telemetry/listen.py 47820, bound 0.0.0.0).
- Topology: direct P2P cable, Mac en8=192.168.99.1/24,
  ThinkPad=192.168.99.2/24 static, no DHCP/router.
- Frame: unicast dst-MAC en8 + src-MAC NIC + ethertype 0800 +
  IPv4(20B,no opts) + UDP(47821->47820) + payload 'KORU <tag>'.
- Checksums: real IP+UDP checksums (both verified valid on wire).
- 'KORU hb' heartbeat every 10s from shell loop — distinguishes
  "kernel alive, display dead" from "never reached NIC stage".
- Boot markers name furthest kmain stage: last marker before silence
  = crash/hang point. For i915 bring-up this is THE oracle.
- Shell cmds (flaky-keyboard friendly): 'net' (status), 'send <msg>',
  'sendb <msg>' (broadcast A/B), 'frame [msg]' (hex dump no-TX),
  hidden 'udp <ip> <port> <msg>' debug.

## COMBINED i915+telemetry ISO (2026-11-07 ~16:57)

Merge native/i915-net-merge = i915-m0 (ce5070a) + net-telemetry.
Conflicts: boot.zig (kept faults.install + i915 comment + net marks),
shell.zig (help lists both i915 and net cmds). i915.zig stage() hooked
to net.mark — every modeset stage emits 'KORU i915: ...' UDP marker.
ISO: dist/koru-i915-net-20261107-1656.iso. On HW: shell 'i915' command
runs modeset; last KORU marker = exact death stage. QEMU-verified net
path; i915 itself is HW-only (no VGA in QEMU -kernel path).

## mb2 header fix (2026-11-07 ~17:06)

Combined ISO failed GRUB: 'no multiboot header'. Root cause: t590-m0's
export-var mb2_header had magic bytes D6 50 E8 52 (u32 0x52e850d6) —
bytes 2-3 swapped vs correct LE D6 50 52 E8 (0xE85250D6). Checksum was
right for the real magic. Fixed in boot.zig; verified magic+checksum
in ELF and -cdrom QEMU boot to 'net: telemetry up'.
ISO: dist/koru-i915-net-20261107-1705.iso (supersedes 1656).

## scanout-alloc merge (2026-11-07 ~17:29)

t590-m0 committed 59e5d55 on native/i915-m0: real pmm.allocContiguous
scanout when borrowed fb <1080p (pitch=7680, ~8MB, align 512→1).
Merged clean into native/i915-net-merge. ISO:
dist/koru-i915-net-20261107-1728.iso. Expect 'modeset' to pass the
fb-size check and proceed to modeset/link-train on HW.

## plane-fix merge (2026-11-07 ~17:48)

t590-m0 committed 7eaa102 on native/i915-m0: plane programming fix —
DSPCNTR format/stride/tileoff corrected vs libgfxinit (pipe.zig +
i915.zig). Prior state: MODESET DONE + backlight ON but black panel,
DSPASURF=0 suspect. Merged clean. ISO:
dist/koru-i915-net-20261107-1747.iso — 'modeset' should now show image.

## stride+format merge (2026-11-07 ~18:00)

t590-m0 committed 86384b0 on native/i915-m0: plane format XRGB8888
(4<<24) + stride verification print (pipe.zig). Prior: display LIVE
with checkerboard+text but compressed/wrapped (DSPASTRIDE=0x200) +
pink fringing (format bits). Merged clean. ISO:
dist/koru-i915-net-20261107-1759.iso.

## stride+console-unify merge (2026-11-07 ~18:38)

t590-m0 committed 1ffd16f on native/i915-m0: console rebase onto
scanout (fb.rebase -> text.zig renders into 0xa00000@7680) + plane
write readback-verify pairs (DSPASTRIDE/DSPASURF/DSPACNTR). Prior:
stride write not landing (readback 0x200 vs intended 7680) + console
fb-writes corrupting scanned image ~10s post-modeset. Merged clean.
ISO: dist/koru-i915-net-20261107-1837.iso.

## plane-bank diag merge (2026-11-07 ~18:57)

t590-m0 committed c0e0f87 on native/i915-m0: plane-bank labels in
dumps + full plane readback set (i915.zig + pipe.zig). Readback
proved stride write not landing: log=7680 but DSPASTRIDE reads
0x200; log says plane=1(hires) but DSPA*(plane-A) regs dumped —
plane-index/register-bank mismatch suspect. Merged clean. ISO:
dist/koru-i915-net-20261107-1856.iso.

## plane-bank enumeration merge (2026-11-07 ~19:08)

t590-m0 committed cbeffb9 on native/i915-m0: dump ALL plane banks
post-modeset — A/B/C x p1/p2 + pipe configs (i915.zig +22). Bank
labels proved only [A]-bank regs touched, all defaults — real
scanning plane is a different bank. Merged clean. ISO:
dist/koru-i915-net-20261107-1907.iso — dump names the real plane.

## stride-unit fix merge (2026-11-07 ~19:15)

t590-m0 committed e84dab3 on native/i915-m0: DSPSTRIDE is in 64-byte
units (12-bit field), not raw bytes — 7680B/64=120=0x78 was the
original correct value; writing raw 7680 overflowed the field ->
readback 0x200. Merged clean (pipe.zig). ISO:
dist/koru-i915-net-20261107-1914.iso — stride should now read 0x78.

## surf+timing merge (2026-11-07 ~19:23)

t590-m0 committed 2436c81 on native/i915-m0: surf=GGTT-offset
confirmed + timing dumps + clean text band (i915.zig+15 pipe.zig+3).
Prior: stride fixed (0x78=7680B) but DSPASURF=0 suspect + pink bar +
garbled text. Merged clean. ISO: dist/koru-i915-net-20261107-1922.iso.

## console-render merge (2026-11-07 ~19:50)

t590-m0 committed e313cf6 on native/i915-m0: per-cell bg fill so
glyphs render on the i915 scanout (text.zig +5). Prior: registers all
correct (1080p60 timing, stride 0x78, size/pos) but console repaint
drew with wrong geometry into the XRGB8888 buffer = wipe/re-render.
Merged clean. ISO: dist/koru-i915-net-20261107-1949.iso.
