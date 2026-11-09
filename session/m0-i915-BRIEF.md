# Commission: M0 — i915/libgfxinit static scanout on ThinkPad T590 (KBL iGPU-630)

## Arbiter session: t590-m0 · report to orchestrator at herdr-core `t1`

## Mission

Light the ThinkPad T590's internal panel via **real GPU modesetting** —
not the GRUB/VBE linear framebuffer we've been using — by porting the
minimal Intel Kaby Lake display-init sequence. Prove pipe/transcoder/
plane/DDI/DP-init/eDP-PPS/panel/backlight on real silicon with a dumb
scanout buffer. This is milestone **M0** of the i915 feasibility plan —
the cheap de-risk before the full KMS driver.

## Why M0 first

Full i915 is ~114k LOC of reference → 20–35k new code (see
`~/src/koru-desktop/session/m6-i915/RESULT.md` — READ IT FIRST, it has
the per-file keep/drop map, the 5 workstreams, and the milestone ladder).
M0 skips all KMS complexity: no atomic commit, no ioctls, no pageflip —
just bring the display up and scan out a static buffer. It proves the
hardest register sequences on real hardware before we commit to M1+.

## References (all local, read before writing code)

- `~/src/koru-desktop/session/m6-i915/RESULT.md` — the feasibility
  report: KBL = DISPLAY_VER 9, HAS_DDI + HAS_PCH_SPLIT (display logic on
  PCH), single eDP on one DDI port, universal planes, llvmpipe scanout.
- `~/src/koru-desktop/session/m6-i915/libgfxinit/` — coreboot's minimal
  Intel display init (Ada/SPARK, ~30k LOC). `common/skylake/` covers KBL
  on one path. **This is the primary port source** — it's designed for
  exactly this: boot-time modeset→static framebuffer, zero Linux deps.
- `~/src/koru-desktop/session/m6-i915/linux/drivers/gpu/drm/i915/` —
  sparse checkout of i915 for cross-checking init sequences.

## Target

`~/src/koru-os-thinkpad` — the native freestanding kernel
(`koru/native/boot.zig`, `text.zig`, `kbd.zig`, `shell.zig`). It already
boots on the T590 via GRUB→VBE fb→text console→shell (commit 7c5b572,
pushed). M0 adds a real GPU modeset path. Produce a bootable ISO/img the
user can flash to SD — same loop as the console work.

## What "done" looks like for M0

A bootable image where, after kernel init, the T590's internal eDP panel
shows a **visible pattern/text rendered through the GPU scanout path**
(not the VBE linear fb) — e.g. a filled dumb buffer with a test pattern
or the console text composited into the GPU framebuffer. Panel backlight
on, correct 1080p mode, no garbage. Serial/console diagnostics still
work as the oracle while the display path comes up.

## Constraints / honest notes

- **Real hardware only** — QEMU has NO gen9 display model; every test is
  a physical flash by the user. Build the payload + ISO, hand over the
  flash instructions, iterate on what the screen shows. The user is the
  hardware oracle.
- Persistent dirs only, never `/tmp` for anything that must survive.
- Do NOT touch `~/src/unikraft` (vma-audit owns it) or other live trees.
- Port-by-hand to Zig is fine (libgfxinit is Ada but small; the KBL path
  is a few hundred lines of init sequence). i915 sequences are the
  cross-check oracle.
- Conditional unknowns for T590 (from RESULT.md §3): panel backlight type
  (PWM vs AUX), eDP EDID source (VBT vs AUX), eDP port letter, whether
  firmware leaves a framebuffer to inherit. Instrument for these.
- If a register sequence hangs the display, that's expected bring-up
  pain — keep console/serial diagnostics alive so a blank screen still
  tells us where it died.

## Reporting

Push receipts to the orchestrator: `hc send t1 '📨 <one-line receipt>'`
at every milestone (display powered, DPLL locked, link trained, first
pixels). Also `prose baton set` + write progress to
`~/src/koru-os-thinkpad/session/m0-i915/NOTES.md`. The user flashes and
reports what the screen shows — treat their description as the oracle.
