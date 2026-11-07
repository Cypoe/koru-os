# M1 — dumb-KMS milestone: object model + dumb buffers + modeset path

Commission: M1 dumb-KMS on the T590 (KBL iGPU-630, eDP). Worktree
`/Users/larsde/src/koru-os-m1`, branch `native/m1-dumb-kms` (from
`native/i915-net-merge`). Goal: replace/extend the proven M0
static-scanout path with a real modesetting path — PCI probe → minimal
KMS object model → dumb-buffer create/map → first pixels via modeset,
not the M0 fixed-1080p pattern-fill hack. Register-init sequence is the
PROVEN libgfxinit port — reused, not re-derived.

## What landed (commit 9dfb471)

- `koru/native/i915/kms.zig` — new module:
  - `Device` object model: 1 crtc (pipe A primary), 2 planes (hires DSP
    + sprite), 1 connector (eDP/DIGI_A, modes = {M1920x1080_60}).
    Objects carry id/kind/bindings/state; modeset resolves them.
  - `dumbCreate(w,h,bpp)`: pmm.allocContiguous → GTT PTEs at a device
    bump offset (`gtt_next`, +128 dummy tail aliasing the buffer's last
    page — safer than M0's continuing-phys) → identity CPU map.
    pitch 64B-aligned; XRGB8888 only.
  - `dumbDestroy` / `dumbGet`; handle table [4].
  - `modeset(conn,crtc,buf)`: the M0 enableOutput sequence driven by
    objects — powerUpEdp → preferredLinkSetting (AUX/DPCD) → pll.alloc
    → trainDP loop (≤2 link fallbacks) → legacyVgaOff → pipe.on →
    backlightOn → dumpDisplayRegs. Commits connector/crtc/plane
    bindings + `gdev.scanout` on success.
  - `rebaseConsole`: fb.rebase + text.syncDims onto the dumb buffer —
    console renders INTO the scanned buffer (the M1 answer to M0's
    compositing gap; the M0 rebase helpers existed but were never wired).
  - `runModeset` ('kms'): probe → dumbCreate(1920,1080,32) →
    fillTestPattern via CPU map → modeset → rebase → retire previous
    scanout buffer. Re-runnable: each run allocates at the next GTT
    offset, so a second 'kms' exercises nonzero DSPSURF on HW.
  - `runBuffer` ('kmsbuf'): create+map+pattern only, no modeset —
    isolates the buffer path from the display path.
  - Test pattern is deliberately unlike M0's checkerboard: yellow
    frame + 8 vertical colour bars + checker strip — a HW photo
    unambiguously names the path.
- `koru/native/i915/i915.zig` — promoted detectCpu, compatibleGpu,
  legacyVgaOff, pchRawClkFreq, stage, diagLine, dumpReg/dumpPlane/
  dumpAllPlanes/dumpDisplayRegs to `pub`. M0 path byte-identical.
- `koru/native/shell.zig` — 'kms' + 'kmsbuf' commands (alphabetic;
  digits 5/6 dead on the T590 keyboard), help text updated.
- `session/m1-dumb-kms/work/build-m1.sh` — macOS build recipe:
  koruc emit (writes output_emitted.zig next to boot_fb.k — the
  copy-to-temp path resolution break documented in m0 NOTES) + zig
  build-exe with the full -M module list. No build-system changes
  needed: kms.zig is a relative import inside the root module.

## Stage markers (wire log)

Every step emits `KORU kms: ...` via net.mark + caps-LED blink +
serial/fb text, same oracle discipline as M0. Order: M1 begin → pci
probe done → panel pp sequencer → power+clocks → port detect → rawclk
→ object model populated → dumb buffer created+mapped → test pattern
filled → modeset objects resolved → panel powered → link settings →
pll allocated → link trained → pipe+plane programmed → MODESET DONE →
console rebased → M1 complete.

## Verification status

- ELF: `zig build-exe` clean (ReleaseSafe, x86_64-freestanding),
  3,146,808 B.
- ISO: `dist/koru-m1-dumb-kms-20261107-2048.iso` (15 MB) — isotree +
  grub-mkrescue (docker koruos-amd64-img) + MBR patch (0x1be=0x83,
  entry0 LBA=0x10). Unique timestamped name per naming ruling.
- QEMU -cdrom: boots to shell (pmm/net/fb-init/shell/hb on serial AND
  listener — the 15:56:44-53 listener.log entries src 192.168.99.1 are
  this boot's slirp-forwarded markers). 'kms' typed via monitor
  sendkey: dispatched, ran probe, failed gracefully
  "FAIL gpu vendor/device 0x1234:0x1111" (QEMU VGA is Bochs, not
  Intel — expected), console+heartbeats continued. No i915 in QEMU —
  the modeset path itself is HW-only, same as M0.
- HW: UNVERIFIED — awaiting user flash. Oracle = UDP listener
  (KORU kms: markers name the furthest stage) + panel (bars+frame =
  dumb-buffer scanout proven; console-over-bars = compositing proven).

## HW test recipe

Flash `dist/koru-m1-dumb-kms-20261107-2048.iso` → shell → `kmsbuf`
first (buffer path only — markers through 'buffer path done', panel
untouched) → `kms` (full path). Expected on success: panel shows
yellow frame + 8 colour bars + checker strip, console text renders
over it at 1920x1080, 'kms returned' prints, KORU markers stream to
192.168.99.1:47820. Second `kms` run = nonzero-DSPSURF exercise.
Compare against `modeset` (M0 path, unchanged) if kms diverges.

## Known bounds / notes

- EDID/DDC not ported — connector mode list is the single native
  1080p60 mode. Mode selection is object-shaped but has one entry.
- Dumb buffer pitch = w*4 (7680B @1080p), no driver-only alignment
  beyond the 64B stride granularity.
- `kmsbuf` buffers are never auto-freed (no scanout to retire) —
  4-run table limit; reboot clears. Documented, not hidden.
- Failed modeset destroys the just-created buffer so handles recycle.
- M0 'modeset'/'i915' command untouched — both paths coexist; running
  M0 first then kms re-inits the same hardware (same proven sequence,
  idempotent in practice, unverified edge).
- GTT bump allocator starts at page 0 — same convention as M0
  (DSPASURF=0 on first buffer). If M0 ran first its PTEs are simply
  overwritten; its scanout is replaced by the kms modeset anyway.
