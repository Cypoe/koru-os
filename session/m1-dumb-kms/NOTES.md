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

## HW flash #1 → CRASH diagnosis + diagnostic ISO (2026-11-07)

`koru-m1-dumb-kms-20261107-2048.iso` flashed on T590: returned to GRUB
menu, ZERO UDP at listener (listener pid 82425 confirmed bound *:47820
and alive — oracle was up). Kernel died before net.init.

Exonerated (all checked against artifacts, not assumed):
- mb2 magic: `d6 50 52 e8` at ELF off 0x1020, wrong order absent.
- grub.cfg: byte-identical to net-telemetry ISO that reached shell on
  this HW (15:54:50 UTC listener.log, src 192.168.99.2).
- ELF phdrs: entry 0x100050, image_end 0x6d9918 (~64KB over proven
  0x6c9918) — sane.
- MBR/partition: QEMU `-boot c` raw-disk boot reaches shell; BOTH
  partition variants (m0's type=0xee/LBA=0x10 and net's type=0x10/LBA=1)
  have HW precedent — not the blocker.
- Code diff vs merge base is inert until `kms` typed (kms.zig never
  runs at boot; i915.zig pub-only; shell dispatch post-shell).

Conclusion: ISO artifact is sound (QEMU -cdrom AND -hda boot to shell).
Pre-NIC code (_start→faults.install→pmm.init→net.init) is unchanged and
memory-only until PCI/e1000e — proven on this HW. Failure is either
environmental (flash/boot-order — kernel may never have run) or a
real-HW-only hang QEMU can't reproduce. Cannot distinguish without a
pre-NIC observable channel.

Fix shipped — commit 83c7d75: caps-LED boot-stage oracle in kmain.
blinkOnce/beepStage/ledSet already existed (used by _start kbled +
i915 stage); wired as bootStage(1..4) before faults/pmm/net:
  1 blink = kmain entered   (_start→long-mode survived)
  2 blinks = faults.install done (IDT live)
  3 blinks = pmm.init done  (memory map parsed)
  4 blinks = net.init done  (NIC armed → UDP markers flow)
Groups separated by ~3 blink-period pauses so counts stay distinct.

New ISO: `dist/koru-m1-dumb-kms-20261107-2102.iso` (7341 sectors,
MBR 0x1be=0x83 LBA=0x10). QEMU -cdrom verified: reaches net.init +
"KORU N2 udp telemetry live" — slow under ARM→x86 TCG (~165s for the
LED timing loops; native HW <1s). Re-flash recipe: watch CAPS LOCK LED
during boot — count blink groups = furthest stage; UDP listener for
post-NIC markers. If 0 blinks → kernel never ran (flash/boot-order).
If N<4 blinks → died at that stage; last UDP marker + LED count
localize it.

## HW flash #1 retry → early-fb oracle ISO (2026-11-07, commit 4255f93)

CORRECTION: caps-LED is a DEAD channel on this T590 — the 8042 LED
path never physically responds on this EC (established earlier; no blink
ever observed). The 83c7d75 LED oracle was abandoned before shipping.

The ONE pre-NIC observable is the PANEL: GRUB's mb2 tag-8 fb keeps
scanning until i915 modesets. New `koru/native/earlyfb.zig` adopts it
at the TOP of kmain — before faults.install/pmm/net — mapping the
~4 GiB LFB with static `epd[]` pd tables (pmm/mmio don't exist yet),
then drives text.zig so each stage renders as a panel line. IDT installs
second so a post-IDT fault FREEZES on "STAGE n" + "!! EXCEPTION vec="
(isrReport already draws via text.puts once text.dims()!=0) instead of
triple-faulting to GRUB. `fb.adoptRaw` publishes an already-mapped lfb;
`fb.init` later re-adopts the SAME phys via mmio.map, which reuses the
epd tables (pdpt[gb] nonzero) — no conflict, verified in QEMU.

kmain stage order (panel line = milestone reached):
  S0 kernel-ran  (earlyfb.init — GRUB fb adopted, banner drawn)
  S1 idt-live    (faults.install done)
  S2 pmm-ok      (memory map parsed)
  S3 nic-ok      (NIC armed → UDP markers flow; console takes over)

Outcome table for next flash:
  GRUB menu persists, no KORU text .... kernel never ran (bad flash/boot)
  frozen "STAGE n" + "!! EXCEPTION" ... ran, faulted at stage n
  last "STAGE n" stays, no more ....... ran, hung at stage n
  S3 + UDP markers .................... healthy to shell

ISO: `dist/koru-m1-earlyfb-20261107-2131.iso` (15,042,560 B, MBR
0x1be=0x83 LBA=0x10). QEMU -cdrom verified FAST (<35s, no LED delays):
serial shows efb:live addr=4244635648, efb:S0/S1/S2/S3 in order, then
fb:init re-adopts phys=4244635648 (same LFB, epd reused) → fb-init/
shell/hb UDP markers. Flash this one; watch the PANEL for the stage
log and the listener for post-NIC markers.

## HW flash #2 → earlyfb4: oracle moved OFF custom page tables (2026-11-08)

`koru-m1-earlyfb2-20261108-1845.iso` on real T590: NO stage bands, backlight
flashes, returns to GRUB, ZERO UDP. Host-side ELF diff vs known-good
i915-net-1949 proved GRUB LOADS the M1 kernel fine (same entry 0x100050,
mb2 magic @0x1020 len=48, same 7-phdr) — it's a RUNTIME crash, not a load
problem. `_start`/GDT/page-tables/mb2_header diffed vs merge base fc509df:
BYTE-IDENTICAL — trampoline exonerated.

Prime suspect: earlyfb's hand-rolled `epd[8][512]` 2MiB PDEs + `pdpt[gb]`
install, sized for QEMU's fb @0xFD000000 (GB3). Real-HW GRUB reports a
DIFFERENT fb phys; if it lands outside the 8-window scheme or maps wrong,
the first fb.koruos_fb_* write #PFs → isrReport→earlyfb.fault repeats the
same wild write → #PF→#DF→TRIPLE FAULT→GRUB. Matches: nothing on screen,
backloader, zero UDP, pre-NIC.

FIX (commit pending): DELETE the custom static tables entirely. earlyfb.init
now runs AFTER pmm.init and maps the fb through the PROVEN `mmio.map`
(pmm-backed hi pd tables — the exact path fb.init uses on real HW, so it
cannot regress what already works). Geometry validation kept (bpp=32,
type=1, pitch>=width*4, pitch<=1MiB, fb<=32MiB); any refusal → oracle blind,
boot continues to shell+UDP. kmain order is now:
  faults.install → pmm.init → earlyfb.init(S0) → net.init → stage(1 nic-ok)
Trade-off: loses the pre-pmm marker window, but pmm.init is memory-only and
proven; the real-HW risk window (net.init PCI/e1000e device touches) stays
bracketed. fb.init later re-adopts the SAME lfb via mmio.map — pdpt[gb]
reused, console coexists (verified).

QEMU -cdrom verified (m1.elf, -m1024): pmm→efb:live addr=4244635648→
efb:S0→pci/e1000e/net→KORU N2→efb:S1 nic-ok→fb:init re-adopt SAME phys→
fb-init/shell/hb. Full healthy boot, markers in order.

ISO: `dist/koru-m1-earlyfb4-20261108-2033.iso` (15,056,896 B, MBR
0x1be=0x83 LBA=0x10). Next flash distinguishes:
  UDP markers + shell, no bands .... oracle blind (mmio.map refused) —
                                   kernel healthy, proceed to kms/kmsbuf
  colored STAGE band ................ exact milestone; frozen red FAULT
                                   vec=n names any post-IDT fault
  still cycles, no banner ........... death genuinely pre-kmain
                                   (GRUB load or _start) — no Zig marker
                                   can see it; instrument _start asm next
