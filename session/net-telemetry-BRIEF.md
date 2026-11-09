# Commission: network telemetry — UDP diagnostic channel for ThinkPad native kernel

## Arbiter session: t590-net · report to orchestrator at herdr-core `t1`

## Mission

Give the bare-metal ThinkPad kernel a way to phone home: a minimal
Ethernet + IPv4 + UDP stack that emits stage-marker datagrams during
boot, so we get a readable diagnostic log INDEPENDENT of the display
(which is currently dead/blind during i915 bring-up). This is a
permanent observability channel, not a one-off.

## Why

Display dies when i915 touches it; keyboard LEDs don't physically
respond on this EC; PC speaker isn't connected. We've lost every
local-output channel. Network can't be blinded by the thing we're
debugging. UDP is the right protocol: stateless, fire-and-forget —
emit a datagram per stage, no handshake, no retransmit.

## Hardware / target

- ThinkPad T590 wired NIC: **Intel I219-LM** Ethernet — e1000e-class
  driver (PCI device, MMIO/IO BAR, TX descriptor rings). Polling TX
  only — NO RX needed for telemetry.
- The Mac (this machine) runs a UDP listener on the same LAN; the
  ThinkPad sends datagrams to the Mac's LAN IP:PORT. User plugs in
  Ethernet.
- Worktree: `~/src/koru-os-net` (branch `native/net-telemetry`) —
  ISOLATED from `~/src/koru-os-thinkpad` where t590-m0 owns i915.
  Do NOT touch the main checkout; all work here.

## What to build (milestone ladder)

- **N0 link up** — PCI probe the I219, map BARs, init the NIC, get
  link-up + MAC address. Prove with a serial/console print (console
  works pre-i915).
- **N1 TX frame** — build + transmit a raw Ethernet frame (or ARP
  request) — prove the descriptor ring actually emits on the wire.
  Listener on Mac sees it (even a broadcast ARP "who-has").
- **N2 UDP telemetry** — static or DHCP-lite IP config, ARP resolution,
  IPv4+UDP emit. Send `KORU <stage>` strings at each boot phase.
- **N3 integration** — hook stage markers into boot.zig so the boot
  log streams to the listener. This becomes the permanent channel.

## Constraints

- Polling TX only — skip RX/interrupts for now (telemetry is
  one-directional).
- Static IP is fine for bring-up (document the assumed subnet/gateway;
  the Mac's LAN IP is the destination).
- Persistent dirs only. Do NOT touch ~/src/koru-os-thinkpad main
  checkout, ~/src/unikraft, or other live trees.
- Produce a bootable ISO in this worktree's own dist/ dir (unique
  timestamped names — see convention below) so the user can flash and
  we watch the listener for markers.

## Reporting

`hc send t1 '📨 <receipt>'` at each milestone + `prose baton set` +
notes in `session/net-telemetry/NOTES.md`. The listener log on the Mac
is the real oracle — coordinate the destination IP/port with the
orchestrator (ask via hc send t1 if unsure of the Mac's LAN IP).
