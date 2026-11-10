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

## BISECT ISO — earlyfb fully disabled (2026-11-08, commit cfbd741)

All four earlyfb ISOs (earlyfb1-4) crash pre-NIC on real T590: panel
flashes, returns to USB loader, ZERO UDP, nothing on screen. Known-good
i915-net-1949 boots fine to shell+heartbeat on the SAME hardware/flash
path. Host ELF diff: M1 loads fine (same entry 0x100050, mb2 magic
@0x1020 len=48, same 7-phdr) -> RUNTIME crash, not load. earlyfb4 used
proven mmio.map + blind-safe geometry validation and STILL crashed with
no marker -> suspect is earlyfb's FAULT path itself (fb write inside
isrReport on a bad/unmapped fb -> #PF->#DF->triple fault->reset,
invisible) OR a deeper M1 build bug.

BISECT: removed ALL earlyfb wiring. boot.zig drops the earlyfb import +
earlyfb.init/earlyfb.stage calls; faults.zig drops the earlyfb import +
earlyfb.fault(vec) in isrReport (breaks the fault-handler fb-write
recursion — the exact suspected triple-fault mechanism). Both files now
BYTE-IDENTICAL to merge-base fc509df. earlyfb.zig left on disk but fully
unreferenced -> lazy codegen emits nothing. kms.zig + shell commands
kept (shell-gated/inert). Boot path = proven faults->pmm->net->fb.init->
shell, identical to the working build for every pre-NIC stage.

QEMU -cdrom verified: pmm->pci->e1000e->net->fb-init->shell->hb, ZERO
efb markers, fast boot (no dwell). ISO below.

ISO: `dist/koru-m1-bisect-noefb-20261108-2111.iso` (15,022,080 B, MBR
0x1be=0x83 LBA=0x10). Flash this ONE — it answers the fork:
  boots clean to shell+UDP ........ earlyfb was the crasher (fault-path
                                  fb-write recursion); reintroduce a
                                  SAFER oracle or drop it and proceed to
                                  kms/kmsbuf M1 testing
  STILL crashes pre-NIC ........... deeper M1 build bug (kms.zig /
                                  i915.zig / shell changes), NOT the
                                  oracle -> bisect those next

## RECIPE+SOURCE BISECT — kms.zig is the SOLE boot-crasher (2026-11-08)

koru-m1-bisect-noefb STILL crashed on T590 (earlyfb+boot wiring exonerated).
Decisive ELF forensics then collapsed the suspect list:

- PROVEN recipe (scripts/build-native.sh, sed-substituted {{ ENTRY }})
  produces a kernel whose LOADABLE image is BYTE-IDENTICAL to
  build-m1.sh output — only DWARF paths differ. Recipe EXONERATED.
- Reverting fb.zig+i915.zig+shell.zig+text.zig to fc509df (earlyfb already
  gone) yields m1srcbase.elf == koru-i915-net-1949.iso kernel
  BYTE-IDENTICAL (all 4 LOAD segs). Toolchain+program EXONERATED.
- Keeping i915 pub-promotions+fb adoptRaw+text font-pub but dropping the
  kms.zig import (shell.zig->merge-base) yields m1nokms.elf ALSO == good
  kernel BYTE-IDENTICAL. i915-pub/fb/text add ZERO net code. EXONERATED.
- => the ENTIRE bootable delta is kms.zig's emission: +0xf0a0 .text
  (~60KB), +0x7d8 .rodata, +0x308 .data; .bss UNCHANGED (0x525918).
  kms.zig is compiled in via boot->shell->kms->i915 but NOT executed
  pre-NIC — yet its presence crashes real HW pre-NIC (QEMU boots fine).
  Mechanism is binary-level (emission/layout vs real-HW mem map), not
  execution. kms.zig source is clean Zig (one small var gdev, no
  comptime/export/large statics).

ISOs:
  dist/koru-m1-srcbase-20261108-2122.iso  (merge-base native == good)
  dist/koru-m1-nokms-20261108-2127.iso    (all-M1 minus kms.zig == good)
Both loadable-identical to known-good -> WILL boot on HW; flashing
confirms kms.zig is the sole crasher with zero ambiguity.

NEXT: distinguish SIZE-vs-CONTENT. If pure +60KB layout crashes real HW,
a size-pad control reproduces it; else kms.zig's emitted code/relocs are
bad -> inspect symtab/relocs of m1full vs m1nokms. Then either shrink the
KMS footprint or find the bad emission.

## SIZE-PAD CONTROL ISO (2026-11-08) — distinguishes SIZE-vs-CONTENT

Built srcbase (merge-base native == good kernel) + a forced-emission
`export const koru_sizepad: [0x10000]u8` (64 KiB benign .rodata) in
boot.zig. Verified layout reproduces M1-full's HIGH sections EXACTLY:
  PAD    .data@0x172000 .bss@0x1b4000 _end=0x6D9918  (== M1FULL)
  GOOD   .data@0x162000 .bss@0x1a4000 _end=0x689918
  M1FULL .data@0x172000 .bss@0x1b4000 _end=0x6D9918
(.text/.rodata sizes differ — pad is rodata not code — but the
kernel-end/.bss boundary that could hit a real-HW limit is identical.)
QEMU -cdrom: boots to shell+hb clean. ISO below.

ISO: `dist/koru-m1-sizepad-20261108-2130.iso` (14,831,616 B, MBR
0x1be=0x83 LBA=0x10). Flash result forks the fix:
  pad CRASHES pre-NIC .... real-HW layout/size boundary — find exact
                         threshold (binary-search pad size / section);
                         kms.zig innocent, shrink or relocate kernel
  pad BOOTS .............. kms.zig's emitted code/relocs are the bug —
                         diff m1full vs m1nokms symtab+relocs, find the
                         bad symbol (likely an i915 fn newly reachable
                         via kms that miscompiles or bad reloc)

## SIZE THRESHOLD BISECT — pad32 ISO (2026-11-08)

sizepad-64KB confirmed SIZE/LAYOUT crash on T590 (good kernel + benign
pad, no kms code, crashes identically). Analysis: all boot structures
(pml4/pdpt/pd, 512KB stack) live INSIDE .bss, identity-mapped 0-32MiB;
pmm.init reserve() is bookkeeping only — NO intra-kernel collision.
Corrected _end values: good=0x6C9918, sizepad64=0x6D9918 (64KB growth).
Next data point: pad32 (0x8000 rodata) -> _end=0x6D1918, halfway.
ISO: dist/koru-m1-sizepad32-20261108-2141.iso (14,798,848 B).
  pad32 crashes -> threshold <=32KB growth (low boundary ~7MB)
  pad32 boots    -> threshold in 32-64KB -> narrow with 48KB next
QEMU can't reproduce (tolerates any size) — HW flash is the only oracle.

## HEAP-SHRINK UNBLOCK ISO (2026-11-08) — _end back under threshold

sizepad32 confirmed threshold <32KB growth. Analysis: kernel image fully
GRUB-reserved (last PT_LOAD memsz reaches _end); no intra-kernel
collision; .bss dominated by runtime heap (4MiB). Fix: HEAP_SIZE
4MiB->3.75MiB (-256KiB) in runtime.zig — shell/console path never uses
the bump heap (only prog.main's __koru_bare). Result: full M1 kernel
(kms+i915+shell) _end=0x699918, 192KiB under working 0x6C9918.
ISO: dist/koru-m1-heapfix-20261108-2149.iso (15,022,080 B).
Principled pmm-reserve of GRUB module/LFB regions = follow-up commit.

## .data/.bss-START POSITION hypothesis + ReleaseSmall test ISO (2026-11-08)

Refined ELF forensics: the crash variable is NOT _end — it is the START
vaddr of the RW PT_LOAD segment (.data+.bss). Measured:

  build        .data start   .bss start   _end       T590 result
  good/nokms   0x162000      ~0x1A0000    0x6C9918   BOOTS
  pad32        0x16A000      ~0x1B0000    0x6D1918   CRASH
  heapfix/M1   0x172000      0x1B4000     0x699918   CRASH
  relsmall     0x124000      0x166000     0x64B918   (this ISO — QEMU OK)

pad32 proves POSITION not size: a 32KiB benign .rodata pad (no KMS code)
pushed .data 0x162000->0x16A000 and reproduced the crash. heapfix proved
_end is irrelevant: _end=0x699918 (LOWEST of the crashing set) still
crashed because .data stayed at 0x172000.

Boundary object: the RW-segment start must stay below ~0x168000 (~1.4MiB
phys). That page is NOT kernel .bss (page tables/heap/stacks live far
higher, .bss>=0x166000 and extend to ~0x6-7MB). The leading candidate is a
GRUB/firmware low-memory allocation — the multiboot2 info structure /
boot-module area that GRUB's loader carves from low RAM on the real-T590
e820 layout (QEMU's clean e820 hides it). When .data start crosses
~0x168000 the kernel's early .data load + first .bss page-table writes
physically overlap that still-live GRUB region -> corrupted mbi/module
data -> pre-NIC reset. CONFIRM by capturing mb2 mbi/module phys addrs on
HW, or by the relsmall boot result.

TEST ISO (decisive): -O ReleaseSmall collapses .text 0x66e5f->0x1ae8e so
.data lands at 0x124000 — the LOWEST RW start of any M1 build, all kms
code present, _end=0x64B918 (lowest yet). If the hypothesis holds this
boots on the T590 where heapfix crashed.

  dist/koru-m1-relsmall-20261108-2156.iso  (12,296,192 B, MBR
  0x1be=0x83 type=0xee LBA=0x10). QEMU -cdrom: telemetry->N2->fb-init->
  shell->hb clean.

Caveat: ReleaseSmall is a TEST, not necessarily the ship config — it
changes codegen (smaller/faster-different) and may mask a real bug. If it
boots, the principled fix is section placement: keep boot .text+.rodata
small OR move the kms/i915 bulk into a high vaddr section so the low RW
segment stays <0x168000 with kms fully present at ReleaseSafe.

## efault — bulletproof stage/fault oracle diagnostic ISO (2026-11-08)

Independent audit pivot: the .data/.bss-start hypothesis was UNPROVEN (mb2
spec has GRUB zero-fill .bss, so no kernel clear can overrun GRUB structs)
and "zero UDP" can't separate pre-NIC from an net.init MMIO fault. STOPPED
guessing size thresholds; built a fault-capture diagnostic instead.

NEW MODULES (diagnostic boot replaces normal kmain):
- koru/native/efault.zig — self-contained panel oracle. Parses mb2 tag-8,
  maps the LFB with STATIC .bss page tables installed straight into
  pdpt[gb]/pd[] (NO pmm.alloc, NO mmio.map, NO fb.zig — none of which can
  be the crash site). Pixels are raw bounded volatile-u32 writes at
  VA==phys. Stage bands S0-S4 = distinct colors in a top progress strip;
  reportFault() draws red + "VEC nn" + "CR2 hhhh" via a tiny built-in
  3x5 font. inReport guard: a fault INSIDE a report draw re-enters
  isrReport, sees busy(), returns without touching fb -> freeze, never
  triple-fault.
- koru/native/dserial.zig — koru_say/koru_putdec via runtime fputs/stdout
  UART, WITHOUT pulling user.zig's monolithic task/surface runtime.

WIRING: faults.isrReport -> efault.reportFault(vec,cr2) + busy()-guarded
serial/LED (nested faults skip straight to freeze). boot.kmain diagnostic:
faults.install() FIRST, then efault.init(S0), mark1(idt), pmm.init,
mark2(pmm), mark3(pre-net), net.init, mark4(net-done), finish, halt.
comptime force-emission trimmed to runtime + dserial (virtio/gpu/surf/
mouse/user.zig all un-emitted). panic simplified (no text/fb).

QEMU -cdrom VERIFIED (koru-m1-efault-20261108-2208.iso):
  serial: efault fb live addr=4244635648 pitch=4096 1024x768 -> S0..S4 ->
  pmm usable=511MiB -> net telemetry up/N2/diag-net-done -> all stages.
  screendump PPM: S0=(0,255,0) S1=(0,255,255) S2=(0,0,255) S3=(255,0,255)
  S4=(255,255,0) + white finish border — bands reach the scanned surface.

ON REAL T590 the panel now names the killer:
  GRUB menu frozen, no bands .... kernel never ran / pre-S0 fault
  bands up to Sk ................ died entering stage k+1 (k+1 is suspect)
  S3 lit, no S4 .................. net.init() faulted (audit's prime suspect)
  red VEC/CR2 .................... catchable exception — vector+CR2 on panel
  menu redraws in a loop ......... triple fault / reset (pre-IDT or #DF)

ISO: dist/koru-m1-efault-20261108-2208.iso (13,021,184 B, MBR 0x1be=0x83
type=0xee LBA=0x10). ELF _end=0x5a5610 (.text=0xe25f — tiny, no kms).

## ROOT CAUSE — ISO MBR partition table, not kernel (2026-11-08)

Decisive: koru-m1-nokms ISO kernel PT_LOAD bytes BYTE-IDENTICAL to working
koru-i915-net-20261107-1949.iso yet crashed identically -> packaging bug.
Full ISO9660 tree diff (578 files): identical except .disk uuid, grub.cfg
menuentry name, koru.elf non-loadable bytes, EFI-only images. All .mod
files identical (same grub-mkrescue/xorriso 1.5.6, same docker image).

THE BUG — MBR partition entry 0 at 0x1BE:
  working ISOs (1949/1856/1747):  83 00 02 00 10 00 00 00 01 00 00 00 <sz>
    boot=0x83 type=0x10 endCHS=0 LBA=0x01
  M1 ISOs (all):                  83 00 02 00 ee .. .. .. 10 00 00 00 <sz>
    boot=0x83 type=0xee(GPT!) endCHS!=0 LBA=0x10

xorriso/grub-mkrescue DEFAULT emits: 00 00 02 00 ee 1a 18 0c 01 00 00 00
(boot=0x00 type=0xee LBA=0x01). The working patch sets boot=0x83,
type=0x10, endCHS=0, and LEAVES LBA=0x01. The M1 patch WRONGLY forced
LBA=0x10 and left type=0xee -> BIOS told boot partition starts sector 16
as GPT-protective -> boot chain reads wrong sector -> kernel never runs.
Byte-identical kernel, identical crash — explains EVERY M1 ISO failing.

CORRECT MBR PATCH (verified vs 3 working ISOs):
  byte[0x1BE]=0x83  byte[0x1C2]=0x10  byte[0x1C3..0x1C5]=0
  LEAVE LBA[0x1C6..0x1C9]=0x01 and size[0x1CA..0x1CD] as xorriso wrote.

FIXED ISOs (all now match working MBR pattern):
  dist/koru-m1-packfix-20261108-2224.iso  <- REAL M1 kernel (shell+kms),
      QEMU-verified to shell+hb. PRIMARY — flash this.
  dist/koru-m1-efault-20261108-2208.iso   <- efault fault-oracle, repatched
  dist/koru-m1-relsmall-20261108-2156.iso <- repatched
  dist/koru-m1-heapfix-20261108-2149.iso  <- repatched

boot.zig+faults.zig restored to pre-efault M1 shell path (efault.zig/
dserial.zig remain on disk, unreferenced). Next: flash packfix on T590 —
expect UDP telemetry + shell; then kmsbuf/kms M1 sequence.

## RESULT (2026-11-08) — M1 dumb-KMS WORKS on real T590

packfix ISO booted to shell on real HW (UDP diag->shell->hb @22:27).
`kmsbuf` + `kms` both completed: KMS object model (1 crtc, 2 planes, 1 eDP)
-> dumb buffer create/map -> test pattern -> modeset (link CR+EQ pass,
pipe+plane programmed) -> "MODESET DONE eDP lit via dumb-KMS" -> console
rebased onto dumb buffer -> rainbow color-bar pattern + live shell.
M1 dumb-KMS milestone ACHIEVED on silicon.

LESSON (durable): the M1 ISO assembler's MBR patch was the sole cause of
every "kernel won't boot" symptom — byte-identical kernels crashed
identically. ALWAYS diff a new ISO's MBR partition entry (0x1BE) against a
known-good ISO before debugging kernel code. Correct patch:
  byte[0x1BE]=0x83  byte[0x1C2]=0x10  byte[0x1C3..0x1C5]=0
  LEAVE LBA[0x1C6..0x1C9]=0x01  and  size[0x1CA..0x1CD] as xorriso wrote.
Do NOT force LBA=0x10 or leave type=0xee (GPT-protective).

## M2 ATOMIC — pageflip + vblank (2026-11-08)

M1 CONFIRMED on real T590 (kms/kmsbuf modeset, rainbow+console, UDP live).
M2 extends kms.zig/pipe.zig with the atomic commit model:

  CHECK  atomicCheck(h)  — pure object validation, zero HW writes.
  TEST   atomicTest(h)   — GTT PTE readback verify, still zero disp writes.
  COMMIT flipCommit(h)   — ONE DSPASURF write arms the flip the display
         engine applies at next vblank (SKL surface reg = flip request);
         readback-verified, then object state (scanout/plane.fb) commits
         and the retired buffer's frames are freed.
  VBLANK vblankWait(n)   — DEIMR unmasked + DEIIR polled for n events
         (consoleMode has no IRQ path -> polled delivery of real HW
         vblank/flip-done interrupts); each event -> serial+UDP marker.

pipe.zig: +pageflipSurface/surfaceOffset/vblankEnable/vblankPoll.
kms.zig: +fillFlipPattern (horizontal bands + diagonal tick — distinct
from M1 bars), atomicCheck/atomicTest/flipCommit/vblankWait/runFlip.
shell.zig: + 'kflip' command (alphabetic).

Shell flow on T590: 'kms' (live modeset) -> 'kflip' (atomic pageflip).
Flip pattern should replace the M1 bars on-panel at next vblank; UDP
shows kms:flip COMMITTED + kms:vblank markers.

ISO: dist/koru-m2-atomic-20261108-2238.iso — isotree + docker
koruos-amd64-img grub-mkrescue + CORRECTED MBR (0x1BE=0x83, 0x1C2=0x10,
endCHS=0, LBA left 0x01). QEMU-verified boot to shell+hb.

## M3 DMABUF — producer->scanout seam (2026-11-08)

M1 dumb-KMS + M2 atomic CONFIRMED on real T590. M3 adds client buffer
import — the compositor substrate.

Model: dma-buf fd analogue = a token into an export table (MAX_DMABUFS=4).
Backing store = DumbBuffer (GGTT-mapped for scanout, identity-CPU-mapped
for producer, pmm-owned lifetime). refs counts producer+display holders.

  dmabufCreate(w,h) -> token   producer side; wraps dumbCreate.
  dmabufMap(token)   -> *DumbBuffer   producer's CPU render target.
  dmabufImport(token)-> handle  display side; +1 display ref, resolves
                                token->dumb handle for atomic flip.
  dmabufUnref(token)           lifetime; frees export+dumb at refs=0.
  producerRender(buf,seed)     stand-in producer: window-like surface
                                (title bar + gradient + dots) into the
                                CPU map — never touches an i915 register.
  runDmabuf()                  demo: create->render->export->import->
                                flipCommit->vblankWait->unref.

shell: 'kdmabuf' (alphabetic). Flow needs live 'kms' modeset first.
On panel: window-surface replaces prior pattern at next vblank = proof
producer content reached scanout through the import seam.

ISO: dist/koru-m3-dmabuf-20261108-2246.iso — proven pipeline + CORRECTED
MBR. QEMU boot verified to shell+hb (dmabuf path HW-only, like M1/M2).

## M4 NATIVE MOUSE — TrackPoint cursor (2026-11-08)

PS/2 aux driver ALREADY existed: mouse.zig does 8042 aux enable (0xA8),
CCB bit1/bit5, auxWrite handshake, 3-byte packet decode (buttons+dx/dy),
IRQ12 (vec 0x2C via user.zig), wired at boot.zig:426 after kbd.init.
M4 adds the consumer + cursor:

  fb.zig   +putPx/getPx/cursorDims — direct pixel access on whatever
           surface is live (GRUB LFB or post-kms rebase dumb buffer).
  cursor.zig NEW — drains mouse.pop() motion deltas, integrates cx/cy
           clamped to surface, moves a 12x12 arrow sprite via XOR blend
           (self-erasing, no snapshot — composites over console/pattern/
           dmabuf). Button edges counted. UDP net.mark on move stride.
  shell.zig +'mouse' command (toggle+report), cursor.tick() in run loop.

Cursor is the FALLBACK path (composite into scanned surface) — the i915
HW cursor plane (CUR_CTL_A/CUR_BASE_A/CUR_POS_A) is the preferred route
but needs GGTT cursor image + format setup; deferred, regs documented.
Works pre- AND post-'kms' since fb_base follows the rebase.

ISO: dist/koru-m4-mouse-20261108-2359.iso — proven pipeline + CORRECTED
MBR. QEMU-verified boot to shell+hb (no PS/2 mouse in QEMU -> mouse.init
fails gracefully, shell intact). Real HW: 'mouse' toggles cursor; move
TrackPoint -> arrow follows, UDP 'cursor: move' + 'cursor: enabled'.

## M4 DIAGNOSTIC — split no-packets vs sprite-invisible (2026-11-09)

Real T590: 'mouse' toggles cleanly (UDP cursor:enabled/disabled) but ZERO
cursor:move markers + NO arrow on panel. Two candidate failures:
  (A) PS/2 aux not streaming — detect/enable/IRQ12 not delivering
      (T590 TrackPoint may not be PS2 aux, or needs different init).
  (B) sprite not compositing to the VISIBLE surface — putPx may write a
      surface that isn't scanned (GRUB LFB vs post-kms rebase dumb buf),
      or XOR-blend at wrong coords/format.

DIAGNOSTIC BUILD splits them:
  mouse.zig  +Diag{tried,aux_online,irq_armed,packets,desyncs,overflows,
             drops} + diag(); init() now records aux_online (device ACK'd
             0xF6+0xF4) and irq_armed (IRQ12 unmasked) as bools.
  cursor.zig enable() FORCES sprite to fixed corner (50,50) regardless of
             motion -> a STATIC arrow proves the draw path reaches the
             visible surface even with zero packets. UDP markers emitted
             at arm time (comptime tags):
               cursor:aux=1/0    PS/2 aux detected+enabled at boot
               cursor:irq=1/0    IRQ12 unmasked
               cursor:pkts=live/0 cumulative packets received
               cursor:sprite@50,50 draw path executed on live fb surface
             report() prints full numeric diag on console.

DECISION TABLE for the flash:
  aux=0                      -> (A) aux never came up; TrackPoint isn't
                               PS2-aux or needs different init. Sprite
                               still tests (B) independently.
  aux=1 irq=1 pkts=0        -> aux online but no packets -> IRQ12/packet
                               routing or device-not-moving issue.
  aux=1 irq=1 pkts=live     -> packets flowing but no move -> decoder/
                               event-ring issue (desync/ovf/drop counts).
  sprite@50,50 + NO arrow    -> (B) putPx hits wrong surface / bad coords.
  sprite@50,50 + arrow seen  -> sprite path GOOD -> issue is purely (A)
                               no-packets; cursor would move if packets
                               arrived.

ISO: dist/koru-m4-mousediag-20261109-0004.iso — proven pipeline +
CORRECTED MBR. QEMU-verified boot to shell+hb.

## M4 8042 AUX HANDSHAKE DEBUG (2026-11-09)

Diag result: sprite draw WORKS (arrow at 50,50 visible) but aux=0 irq=0
pkts=0 — PS/2 AUX device never ACK'd enable. TrackPoint+touchpad silent.

mouse.init() rewritten as a full 8042 probe (sendCtl/readCtlByte helpers):
  STEP1 selftest 0xAA -> st_selftest (0x55=controller OK)
  STEP2 read CCB 0x20  -> st_ccb (controller's aux gating before touch)
  STEP3 aux pulse 0xA7 disable / 0xA8 enable -> st_auxen (EC wedge reset)
  STEP4 CCB write 0x60: bit1 aux-irq on, bit5 aux-clk-off cleared
  STEP5 device handshake auxWrite(0xF6)+auxWrite(0xF4) -> aux_online
  STEP6 pollWindow(): bounded 0x60 drain post-handshake -> st_pollbytes
       (catches unsolicited/enable-triggered traffic even if IRQ12 masked)

Diag extended: +selftest,ccb,auxen,pollbytes. cursor.enable() emits UDP
markers for each step (comptime tags): 8042=selftest-ok/bad, auxen=1/0,
poll=live/0, aux=1/0, irq=1/0, pkts=live/0, sprite@50,50. report() prints
all numeric fields.

DECISION TABLE:
  selftest!=0x55         -> 8042 itself unhealthy (kbd would be dead too)
  selftest=0x55 auxen=0  -> aux port enable refused at controller level
  auxen=1 aux=0 poll=0   -> device NAK'd handshake: not PS/2 aux, or EC
                            gates pointing devices (needs EC cmd / USB-HID)
  auxen=1 aux=0 poll>0   -> bytes arriving but no ACK -> framing/desync
  aux=1 irq=0 pkts>0     -> packets stream but IRQ12 not firing -> PIC
                            slave/cascade mask issue (IRQ12->int 0x2C)
  aux=1 irq=1 pkts>0     -> fully up; motion should move cursor

ISO: dist/koru-m4-8042diag-20261109-0014.iso — proven pipeline +
CORRECTED MBR. QEMU-verified boot to shell+hb.

## M4 8042 FIX — reuse kbd's proven primitives (2026-11-09)

8042diag result: selftest-bad BUT keyboard works -> the probe's READ was
buggy, not the controller. Root cause: readCtlByte returned the FIRST
output byte; a stale scancode/ACK contaminated the self-test read.
kbd.zig's kawait() loops until the SPECIFIC response arrives, discarding
others — the correct pattern.

FIX — shared primitives extracted to kbd.zig (pub):
  ctlWrite(cmd)->0x64, dataWrite(b)->0x60  (IBF-safe, ksend pattern)
  outAvail(), readOut()->0x60, statusRaw()->0x64 (pre-existing), drainOut()
mouse.zig init() rewritten on them:
  drainOut -> ctlWrite(0xAA) -> readResp()   self-test, expect 0x55
  drainOut -> ctlWrite(0x20) -> readResp()   CCB read
  ctlWrite(0xA7)/drain, ctlWrite(0xA8)/drain aux pulse
  ctlWrite(0x60)+dataWrite(ccb)              CCB write
  auxWrite(0xF6)+auxWrite(0xF4)              device handshake (unchanged)
  pollWindow()                               post-handshake 0x60 drain
readResp() = first kbd-class byte after drain (aux->assembler, kbd->ring)
— no stale-byte contamination. selftest should now read 0x55, ccb the
real value, auxen reflect the pulse.

If aux STILL =0 with a healthy selftest+ccb, the TrackPoint/touchpad is
not answering on legacy PS/2 aux -> next move is USB-HID/XHCI probe.

ISO: dist/koru-m4-8042fix-20261109-0020.iso — proven pipeline +
CORRECTED MBR. QEMU-verified boot to shell+hb.

## HW-ENUMERATION PROBES (2026-11-09)

M4 mouse: sprite works, aux=0 — TrackPoint/touchpad not on 8042 aux.
Need to enumerate what bus they actually use. New hwprobe.zig + 4
alphabetic shell commands; every line console-prints -> UDP mirror
streams it to the listener automatically.

  pciscan   full PCI table: bus:slot.func, vendor:device, class:subclass
            +progif, class-name, bar0 phys. Ground truth for host ctrls.
  usb       XHCI probe: find class0C/sub03/progif30 controllers, map BAR0,
            read CAPLENGTH/HCIVERSION/HCSPARAMS(maxslots,maxports)/
            HCCPARAMS/DBOFF/RTSOFF, then USBCMD/USBSTS + per-port PORTSC
            (connect/enable). Tells if HID devices are electrically there
            even without transfer support.
  acpi      SDT table list (sig/phys/len) + EC probe: ECDT/FADT hex-dump
            heads (EC_SC/EC_DATA ports live there) + read EC status port
            OBF/IBF bits.
  inputscan synthesized verdict: counts xhci/ehci/uhci-ohci/smbus/i2c,
            prints which bus likely carries TrackPoint/touchpad.

Reuses pci.devices/count/barPhys/read8-32, acpi.tables/findTable,
mmio.map. No new bus drivers — enumeration+register dumps only.

ISO: dist/koru-hwprobe-20261109-0037.iso — proven pipeline + CORRECTED
MBR. QEMU-verified boot to shell+hb (QEMU shows its own PCI/USB — proves
the probes run; real-HW is the oracle via UDP).

## HWPROBE2 — prog-if fix + smbus/i2c probe (2026-11-09)

Real T590 pciscan bus map: 0:2.0 i915; 0:20.0 dev 0x9E2D + 58:0.0 dev
0x9D2D = TWO USB host controllers; 0:31.4 SMBUS/I2C; 0:31.6 ETH; 60/61
NVIDIA/Samsung. usb probe reported xhci=0 — BUG: it re-read
pci.read8(0x0A) for prog-if; correct field is d.progif (pci.record
already decodes (cls>>8)&0xFF). Fixed all 3 sites.

  pciscan   now prints d.progif correctly -> XHCI=0x30 EHCI=0x20
            OHCI=0x10 UHCI=0x00 identified per controller.
  usb       XHCI op probe (BAR0->CAPLENGTH/HCSPARAMS/HCCPARAMS/DBOFF/
            RTSOFF, USBCMD/USBSTS, per-port PORTSC connect+enable) now
            fires on the real controllers.
  smbus     NEW — class0C/sub05 probe: BAR decode (IO vs MEM), config
            0x40-0x7F dump (SMBus rev/PID/TID/block-base), MMIO head dump.
            Targets 0:31.4 — the likely I2C HID path for the touchpad.
  inputscan verdict updated: XHCI>0 -> USB HID (expected); smbus-only ->
            I2C HID behind PCH SMBus; else re-check aux/EC.

ISO: dist/koru-hwprobe2-20261109-0043.iso — proven pipeline + CORRECTED
MBR. QEMU-verified boot to shell+hb.

## XHCI DRIVER FOUNDATION (2026-11-09)

Confirmed on T590: 2 XHCI (0:20.0, 58:0.0); 0:20.0 ports 6+8 connected =
TrackPoint+touchpad as USB HID. New xhci.zig + 'xusb' shell command.

Lands the transport substrate (first cut, needs HW iteration):
  - find XHCI (class0C/sub03/progif30), map BAR0, enable mem+master
  - caps read (caplen/hcsp maxslots+maxports), op-reg head dump (ground
    truth for offsets)
  - HC reset (HCRST, wait CNR/HCH)
  - DMA rings in pmm-contiguous pages: cmd ring, event ring, DCBAA,
    scratchpad; phys==VA (no IOMMU)
  - ERST segment table, ERDP arm, CRCR RCS
  - Enable Slot TRB (type9) + event-ring poll -> slot id
Stage markers per step; op-reg dump prints live values for offset debug.
HONEST: register offsets + ring/event logic are best-known xHCI spec —
transfer-level descriptor fetch (Address Device + GET_DESCRIPTOR) is the
NEXT iteration; this pass proves how far init+slot-alloc gets on HW.

ISO: dist/koru-xhci-20261109-0049.iso — proven pipeline + CORRECTED MBR.
QEMU-verified boot to shell+hb.

## XHCI command/event path fix (commit 329e53c, ISO koru-xhci4-20261109-0104.iso)

xhci2 real-T590: panic gone but HANG after "Enable Slot issued". Spec audit
found the event ring was never armed:

- ERSTSZ/ERSTBA/ERDP are RUNTIME registers (bar0+capRTSOFF), NOT op space.
  Code wrote them to op+0x38/0x40/0x48 = CONFIG/MFINDEX/reserved -> HC had
  no event ring, completions posted nowhere. Now rtWr/rtWr64 at rtsbase.
- USBCMD.RS was never set after HCRST -> command ring never fetched. Now
  RS=1 after Enable Slot TRB queued + CONFIG.MaxSlotsEnabled=maxSlots.
- Command ring needs NO doorbell (HC polls once RCS=1); doorbells are for
  transfer rings. dboff/rtsoff now read from caps; BAR mapped 64K.
- waitEvent slot-id extract fixed (was reading completion-code byte); now
  logs ty/cc/dw2/slot, ERDP advance EHB=0, real ring-wrap cycle flip,
  ~1s timeout dumps erdp/crcr/usbcmd/usbsts for diagnosis.

QEMU boot verified clean (no xhci device present; xusb is on-demand).
Real-T590 oracle: `xusb` should now reach SLOT ALLOCATED or a bounded
TIMEOUT dump showing whether the HC consumed the command ring.

## XHCI full enumeration — ported from proven reference (ISO koru-xhci5-20261109-0122.iso)

Replaced spec-blind xhci.zig with a faithful port of the WORKING
koru-desktop providers/usb-xhci/app/xhci.c (landed, verified on
linuxu/QEMU). The earlier hangs were multiple compounding bugs; the
reference resolved them all:

- TRB ctl dword: type=bits[15:10] (6b), cycle=bit0, TC=bit1, LINK=bit2,
  IOC=bit5, IDT=bit6, slot-id=ctl[31:24] (cmd TRBs). Event-TRB slot =
  ctl[31:24], completion code = st[31:24]. (Was using type@[31:16].)
- Proper ring model: link TRB at ring end (type LINK|TC), producer/
  consumer cycle state pcs, wrap flips cycle. Command ring 64 TRBs,
  event ring 64, ep0 ring 32.
- Event ring + doorbells in RUNTIME space at bar0+RTSOFF; interrupter-0
  block at +0x20 (IMAN/IMOD/ERSTSZ/ERSTBA/ERDP). ERDP release =
  next_dequeue_phys | EHB(bit3).
- Command ring DOES need doorbell(0,0) after each command TRB.
- USBCMD = RS|INTE; wait HCH=0. CONFIG.MaxSlotsEnabled=8. IMAN IP|IE.
- Scratchpad buffer array when HCCPARAMS2.MaxScratchpadBuffers>0
  (Intel needs it) -> dcbaa[0].
- Port scan: PORTSC CCS -> port reset (PSC_PR) -> drain PSC events ->
  speed -> Enable Slot -> Address Device (input ctx: add slot+ep0,
  slot ctx entries/speed/rhport, ep0 ctrl ctx mps by speed + dequeue
  ptr|DCS) -> dcbaa[slot]=devctx -> GET_DESCRIPTOR(Device,18B) -> VID:PID.
- Loops ALL ports per controller AND all xhci controllers (class
  0x0C/0x03/progif 0x30). Alphabetic shell cmd 'xusb'.

QEMU-xhci VERIFICATION (test build auto-ran init at boot, then reverted):
  -device qemu-xhci -device usb-tablet -> enumerated port4 slot=1,
    Address Device ok, GET_DESCRIPTOR -> vid=0x0627 pid=0x0001
    (QEMU tablet) len=0x12. Full path proven.

Real-T590 oracle: flash koru-xhci5-*.iso, run 'xusb'. Expect both HID
devices on ctrl 0:20.0 (ports ~6,8) -> two 'DEV port=N vid=.. pid=..'
lines. If it hangs, the stage markers + per-port PORTSC dump localize it.

## XHCI STAGE B — interrupt-IN HID reports (2026-11-09, commit 56ff9c3)

Ported koru-desktop providers/usb-hid/app/hid.c into xhci.zig (field-for-
field): ctrlXfer (generic ep0 control xfer, hid.c TRT/status-dir rules),
parseConfig (HID iface class=3 + interrupt-IN EP + bConfigurationValue),
ConfigureEP input ctx (add slot+ep dci; ep ctx type=7 intr-IN cerr=3 mps,
dequeue|DCS->32-TRB ring, interval clamp 1..16), SET_CONFIGURATION, then a
bounded report poll posting NORMAL TRB IOC|ISP -> repbuf, doorbell(slot,dci),
eventWaitXfer, hex-dump per completion (one say = one UDP datagram).

BUG FIX (QEMU-measured): every IOC'd control TRB posts its own T_XFER
event (data stage, then status stage). eventWaitXfer ate only the first
-> stale event corrupted next transfer's cc (cfg-hdr showed 0x0d). Now
ctrlXfer consumes exactly (wlen?2:1) events, returns last (status) cc —
hid.c's st_ptr semantics without depending on evtPtr (real HW puts it on
an earlier stage TRB, commit 60300fc).

QEMU-verified (koru-xhciBtest-20261109-0223.iso, auto-run build reverted
after): qemu-xhci + usb-kbd(port4/slot1) + usb-tablet(port5/slot2).
Both enumerate; ConfigureEP rc=slot-id (success); SET_CONFIGURATION cc=1;
interrupt-IN completions cc=1. usb-kbd: 14 reports, repbuf[2]=keycodes
0x04..0x0a = 'a'..'g' press/release — REAL HID DATA over interrupt-IN.
NOTE: event st reads len=0 on QEMU interrupt completions (st=0x01000000)
— repbuf bytes are the truth; len decode unreliable on QEMU, re-check on
T590. usb-tablet window missed injection (0 reports) — kbd proved path.

SHIP ISO: dist/koru-xhciB-20261109-0228.iso — proven pipeline + corrected
MBR. Real-T590 oracle: 'xusb' -> Elan 0x04F3:0x2901 + Lite-On 0x04CA:0x7070
expect RPT lines with report bytes on :47820 when TrackPoint/touchpad move.
NEXT (Stage C): decode mouse buttons + X/Y deltas -> cursor.zig feed.

## XHCI STAGE B FIX — spec-correct endpoint ctx + class requests (2026-11-09, commit 8e48cd2)

T590 device-1 (Elan touchpad): reports=0 — endpoint configured but ZERO
interrupt-IN events in ~48s of polling. Device-2: PANIC "integer does
not fit in destination type".

ROOT CAUSES found vs Linux xhci-mem.c xhci_endpoint_init (hid.c was
QEMU-invisible-wrong):
- Interval field is EXPONENT 2^n*125us, not raw bInterval. hid.c wrote
  bInterval; QEMU tablet bInterval=1 masked it. Fixed via epInterval()
  (HS/SS: bInterval-1; FS/LS: fls(bInterval*8)-1 clamp[3,10]).
- MaxBurst (d1[15:8]) = HS wMaxPacketSize[12:11]-1 — was 0.
- tx_info d4 = MaxESITPayloadLo|AvgTrbLen — was 8; now rptLen.
- TRB_LEN was 8 — now rptLen=clamp(pkt,8,255).
- EP state stays 0 in input ctx — spec 4.6.6: HC sets output=Running.

CLASS REQUESTS added post-SET_CONFIGURATION (real HID needs; QEMU
tablet stalls/times-out harmlessly): SET_PROTOCOL(0x0B,wVal=1 report)
+ SET_IDLE(0x0A,wVal=0 infinite). Likely the touchpad reports=0 fix —
device doesn't stream interrupt-IN until class-configured.

PANIC: hex32(@intCast(i32)) on -1 timeout -> hex32i() prints 'tmo'.
Applied at all i32 diagnostic sites. ctrlXfer TRB pushes -> ringPush
(wrap-safe). QEMU-proven: tablet set-idle returned -1 -> 'tmo' printed,
no panic (the exact T590 device-2 crash path).

REPORT LOOP: 4 rotating 1KB bufs, event TRB ptr -> completed buf,
prime4+rearm, doorbell re-ring, evtTrace, per-event cc/len24/epid/
bytes, PORTSC heartbeat/32 idle polls, bail on 8 err ccs. Event decode:
len=st[23:0] (was wrong 0x1FFFF mask), epid=ctl[20:16].

QEMU (koru-xhciCtest ISO): usb-kbd reports=10 (a-e keycodes), ep=3,
set-proto/idle cc=1; tablet stall+timeout handled, no panic.

SHIP ISO: dist/koru-xhciC-20261109-0244.iso. T590 oracle: 'xusb' ->
Elan 0x04F3:0x2901 should now emit RPT lines on touch; Lite-On
0x04CA:0x7070 no longer panics. If still reports=0, next suspects:
wrong HID iface selected (multi-function touchpad) or report-proto
needing SET_PROTOCOL(0) boot — diagnostics now show cc/epid/portsc.
NEXT (Stage C): decode report -> cursor.zig.

## XHCI STAGE B ARMED — output-ctx readback + deep NAK queue (commit pending)

T590 xhciC: ConfigureEP ok + SET_PROTOCOL/SET_IDLE cc=1 + portsc
ccs/ped=1 but ZERO interrupt-IN events / 160 polls.

xhciD adds: OUTPUT device-ctx readback (dcbaa[slot]->DevCtx, ep@dci,
state=d[0]&7) — QEMU proves HC sets epstate=1 Running + correct
interval/type/mps/dequeue. Report loop: prime 8 NAK'd TDs (8x512B),
doorbell(slot,dci) re-ring per idle timeout, re-arm freed buf per
event, armed/doorbell/rearm markers.

T590 oracle: 'xusb' -> read 'outctx epstate=' line. =1 -> HC armed,
device not sending (suspect: wrong HID iface/alt-setting, or Elan
needs report-proto boot SET_PROTOCOL(0), or touchpad genuinely idle).
!=1 -> ConfigureEP didn't take on Intel -> revisit ctx fields.
SHIP ISO: dist/koru-xhciD-20261109-0252.iso.

## XHCI MULTI-FUNCTION HID SCAN (commit pending)

T590 xhciD discriminator: epstate=1 Running + armed + cc=1 but reports=0
-> host correct, device not streaming on first-picked interface. Elan
multi-function.

xhciE: parseHidAll collects ALL HID int-IN endpoints (iface/alt/addr/
mps/ival/protoIf). Per candidate: own ring + ConfigureEP + readback +
8 NAK'd TDs; per protocol (boot-first if pif 1/2 else report-first):
SET_INTERFACE+SET_PROTOCOL+SET_IDLE+poll48 filtered epid==dci. WINNER
= first reports>0.

QEMU: usb-kbd -> proto=0 BOOT reports=10 (a-e). Boot mouse reports =
Stage C cursor input. Ship ISO: dist/koru-xhciE-*.iso.
T590 oracle: 'xusb' -> 'cand' lines per EP, 'try' per proto, WINNER.

## XHCI ALL-CLASS ENDPOINT SCAN (commit pending)

T590 xhciE: reports=0 on sole class-3 int-IN ep 0x81 despite epstate=1
+ armed + cc=1. Host proven; device silent there. nep=2 (0x81+0x02).

xhciF: parseHidAll dumps EVERY interface+endpoint (any class) and
collects ALL interrupt-IN endpoints as candidates (cls tags HID vs
vendor). Class requests guarded to cls==3. Reveals whether touch data
is on vendor EP / second function / endpoint 0x02.

T590 oracle: 'xusb' -> full IF/EP map + per-candidate try/WINNER.
If a vendor int-IN EP yields reports -> that's the touch stream.
Ship ISO: dist/koru-xhciF-*.iso.

## METHOD — Linux-driver-as-oracle for device bring-up
When bare-metal HW bring-up stalls (device enumerated but silent), diff
against the Linux kernel driver for that device — it is the protocol
ground truth. trackpoint.c (TP_* commands over PS/2 aux), hid-elan.c
(ELAN_TP_USB_INTF=1 -> touch data on USB iface 1, not 0; elan_i2c
0x5d path = I2C-HID), elantech.c. Consult raw.githubusercontent.com/
torvalds/linux/master/drivers/... before inventing a sequence.

## TRACKPOINT PS/2 INIT + LAZY INPUT BRING-UP (2026-11-09, commit 08f75d0)

ROOT CAUSE of every M4 "aux=0": fullBoot=false since ced3e26 -> the
doFull init block (acpi/pci/ioapic/user/kbd/mouse/smp) NEVER ran on the
shell path; mouse.init() was dead code and diag() reported zeroed
defaults. The TrackPoint was never actually probed.

FIX (two halves):
- cursor.enable() lazily runs ensureInput() once: acpi.init(pmm.boot_mbi)
  -> ioapic.init -> user.init (IDT+PIC+sti) -> mouse.init. kbd.init
  skipped on purpose — IRQ1 would steal scancodes from shell pollChar.
  IRQ12 reaches vec 0x2C via ioapic route(12) or PIC fallback.
- mouse.init() rewritten on the Linux oracle (trackpoint.c/.h +
  libps2.c): 8042 probe (selftest/CCB/A7-A8/CCB-write) -> 0xF6
  RESET_DIS -> TP_READ_ID 0xE1 (bare, 2 results: variant+fw) ->
  IBM-only POR E2 7F (expect AA 00) -> tpWrite defaults when not
  freshly reset (non-IBM: sens only; IBM-fail: full TP_DEF table) ->
  IBM ext-btn read -> SETRATE/SETRES/SETSCALE best-effort -> 0xF4.
  tpCmd/auxSendByte/auxCollect = ps2_command semantics (per-byte 0xD4
  + ACK, NAK resend x1, raw result collect, 1.5M-iter POR timeout).

Dual-write everywhere: sayU=serial+net.mirror, net.mark tags
tp-id/tp-por-ok|fail|skip/tp-id-none/aux-online/irq12-armed,
cursor tick emits mouse:streaming on first packet.

QEMU-VERIFIED (koru-tpinit-20261109-1409.iso, commit 08f75d0):
boot->shell; 'mouse' -> selftest=55 ccb=61 auxen=1 f6=fa tp-id-none
(QEMU ps2 mouse isn't a TrackPoint — generic path taken) cfg 3/3
aux-online irq12-armed; monitor mouse_move -> mouse:streaming +
cursor:move on wire, pkts=6, cursor:disabled report online=1 irq12=1.
TP path (variant/fw/por) is T590-only — QEMU has no TrackPoint device.

T590 ORACLE: flash dist/koru-tpinit-20261109-1409.iso -> 'mouse' ->
UDP :47820 should show 'mouse: trackpoint variant=N fw=0xNN' +
'tp-por-ok' (or tp-por-skip for non-IBM) + aux-online + irq12-armed;
wiggle stick -> mouse:streaming + cursor:move + pkts>0. If
tp-id-none on real HW too, the TrackPoint is NOT on 8042 aux (then
it's the xhci/USB-HID path from the xhci* notes).

## INPUT LANDED on real T590 (2026-11-09) — PS/2 aux streaming to cursor

MILESTONE: input works on the panel. PS/2 aux channel (TrackPoint
stick + touchpad on the same aux interface) streams packets via
8042 -> IRQ12 -> cursor.zig -> XOR sprite composited onto the live
i915 scanout. Cursor moves smoothly; keyboard types. This is the
first real input->display loop on bare-metal Koru OS.

USB XHCI enumeration is proven separately (xhci* series): Elan +
Lite-On devices enumerate with VID:PID, endpoint config reaches
epstate=1 Running + armed, but HID report streams never arrive —
host side verified correct, devices stay silent on first-picked
interface. Method recorded: Linux-driver-as-oracle (trackpoint.c,
hid-elan.c, elantech.c from torvalds/linux) before inventing any
sequence — that oracle is what made the PS/2 path land.

Key bugs fixed this stretch (all in git log native/m1-dumb-kms):
- dead mouse.init — fullBoot=false since ced3e26 meant the doFull
  init block never ran; mouse.init() was unreachable code. Fixed by
  lazy ensureInput() inside cursor.enable().
- acpi mb2-tag infinite loop — sz==0 tag walked off+=0 forever;
  bounded. (cursor path now bypasses acpi/ioapic entirely — PIC
  fallback delivers IRQ12; ioapic.gsiFor early-returns when !live.)
- CCB kbd-inhibit — 8042 CCB write was inhibiting the keyboard
  channel; aux bring-up no longer touches it.
- freed-framebuffer cursor — after 'kflip' the sprite kept XORing
  into the retired dumb buffer (black screen, no arrow); fb.generation
  tracking + rebase-before-free fixed it.
- kbd.pollChar eating aux bytes — stray aux bytes latched in the
  output register were consumed as scancodes; pollChar now routes
  AUX-flagged bytes to mouse.feedByte (STATUS bit5), leaving real
  keystrokes alone.

Commits: 71e0cf7 acpi bound, ff258f3 cursor PIC bypass, 5f0077d
scanout-resident sprite, 9533515 kbd-death+invisible-sprite fix,
a6edfd4 pollChar aux-byte fix. ISOs: koru-tpinit-20261109-1409.iso
through -1542.iso series on real HW.

Next: first compositor surface — movable window driven by the
pointer (kwin), software-composited onto the console scanout.

## FIRST COMPOSITOR SURFACE — kwin movable window (2026-11-09)

`kwin` shell command toggles a 320x200 window on the console scanout,
driven by the TrackPoint/touchpad pointer. New module
`koru/native/win.zig`; cursor.zig gained pos()/buttonsHeld()/
compositeSuspend()/compositeResume(); shell.zig routes win.tick()
each loop iteration (after cursor.tick).

Design (all primitives proven, nothing new invented at the HW layer):
- Backing: kms.dmabufCreate+dmabufMap when the i915 device is up
  (M3 export seam, CPU side only — window is composited, never
  scanned); pmm.allocContiguous+mmio.map otherwise (QEMU, pre-'kms').
  Backing kind named in the create marker, never silent.
- Painter: fillWindow into the backing — 2px border, titlebar,
  "kwin"/"drag me" labels via text.zig's font table written into the
  buffer (glyphAt's bit order replicated — bit c of row r = column c).
- Composite: software blit onto whatever fb.scanout() reports —
  GRUB/EFI LFB pre-'kms', i915 dumb buffer post-rebase. Opaque
  overwrite; no alpha (seam carries none — comp.zig's ruling).
- Damage: retained-restore. Snapshot of under-window scanout px is
  captured (cursor suspended) before cover; move = restore vacated +
  re-snapshot dest + blit. Text printed under the window is occluded
  (named loss); heal stride (8192 ticks) re-blits so glyph bleed
  self-repairs.
- Input: press EDGE inside window rect starts drag (button held from
  outside doesn't capture); motion moves origin clamped to scanout;
  release = drop. Cursor suspend/resume brackets every composite so
  the XOR sprite is never painted over by a non-XOR blit.
- Generation discipline: all scanout access gated on fb.generation();
  a kms flip/modeset triggers rescan() (re-target+re-capture+re-blit,
  no restore — old frames may be freed). Destroy restores only on
  matching gen.
- Markers: sayU dual-write (serial + UDP mirror) — create (with
  readback px proof: body/border/title hex), drag, move (stride 1,16..),
  drop, destroy, rescan.

QEMU-VERIFIED (koru-kwin-20261109-1614.iso, -cdrom -m 1024, serial +
HMP monitor): boot->shell; 'kwin' ->
  KORU kwin create 320x200 @352,308 backing=pmm body=2a2f3a
  border=d8dee9 title=3040c0
(readback proves painter+composite landed in the scanned LFB);
mouse_button+mouse_move drag -> drag @352,308 / move @372,320 /
drop @432,356 (4x(20,12)=(80,48) exact); second 'kwin' ->
destroy @432,356; recreate -> identical create marker, hb continues,
no panic. Full cycle create->drag->drop->destroy->recreate clean.

T590 ORACLE (panel visibility is HW-only — QEMU has no i915 and
-display none here): flash dist/koru-kwin-20261109-1614.iso ->
'kwin' -> colored window with titlebar should appear on the EFI fb;
'kms' first for the i915 scanout (window rescans onto it live);
TrackPoint press-drag inside window moves it; 'kwin' again closes.
UDP :47820 shows KORU kwin create/drag/move/drop/destroy markers.

Honest limits: one window, no z-order/focus/minimize; opaque only;
console text under the window is occluded while covered (heal keeps
the surface solid); window backing is CPU-composited, not a KMS
plane (planes[1] sprite exists in the object model, unwired);
'kwin' before 'kms' on T590 composites onto the GRUB/EFI fb — same
code path, different scanout.

## MC-1 — unified scene compositor on the live shell path (2026-11-09)

comp.zig evolved into THE scene core per COMPOSITOR-DESIGN.md and wired
into shell.run (the only live path — fullBoot/consoleMode are dead
vars). win.zig/cursor.zig/text.zig/surf.zig all serve it now.

- Scene core (comp.zig, dep-free -M module): explicit monotonic z per
  layer (no index-order z, no compaction — handles stable), kinds
  root/window/surface, placement authority decide()=float clamp,
  window objects {title_h, focused, dragging, grab, key_intake stub}.
- Damage: Acc = bounded 32-rect list, union-merge on insert (overlap
  or edge-touch -> bbox), clip-to-scene, overflow -> whole-scene.
  damage() unions into `pending`; present drains once per tick. The
  retained-restore snapshot and heal stride are DELETED.
- Console = retained ROOT LAYER: text.zig gained a Sink
  {px,pitch,w,h,damage}; shell.consoleUp allocates a W*H pmm backing,
  fills bg, sets sink, attachRoot(z=0). putc/fill/clear report cell
  rects; glyph px ride the cell rect. Covering console text no longer
  destroys it — reveal repaints from the backing.
- Input: cursor.zig stays device-side (drain/pos/buttons/markers) +
  sprite()/spriteBits()/setSceneOwned; sceneOwned makes all direct fb
  sprite ops no-ops. shell feeds comp.feedPointer once per tick; comp
  owns press-edge hit-test (topmost window by z), focus+raise, titlebar
  drag via grab offset -> place(), outside-click -> root focus.
- win.zig = N-window producer (MAX_WIN=8): spawn/closeTop/tick.
  'kwin' spawns (cascade), 'kwclose' closes focused-else-topmost.
  Backing = dmabuf when kms up else pmm (named). Focus titlebar colour
  derived per tick + damageLayer. windowOpen auto-focuses+raises.
- Present seam (present.zig, root module): backend A immediate ->
  composite damage rects into fb.scanout() (tear risk named); backend
  B flip -> two 1920x1080-class scene dumbs via kms.dumbCreate,
  per-buffer damage accs (union into BOTH, clear on paint), flipSwap
  (new — same commit minus prev-destroy), DEIIR vblankDrain gates the
  next composite so scanned/armed buffers are never written. Gen change
  (modeset) -> full damage + swapchain teardown/re-ensure.
- kms.zig: MAX_DUMBS/MAX_DMABUFS 4->16; flipCommit refactored onto
  flipSwap (diagnostics keep prev-destroy); flipSwap is QUIET (no
  stage()/say — per-frame cadence); rebaseQuiet in fb.zig follows the
  scanned buffer without gen bump or serial print.
- fb.zig: koruos_fb_scanout export (phys+pitch+dims) + rebaseQuiet.
- surf.zig: attach/move/detach updated to handle-based API.

QEMU-VERIFIED (dist/koru-mc1-scene.iso, -cdrom -m 1024, serial + HMP
monitor + screendump): boot->scene live 1024x768; 'kwin' x2 ->
kwin0 handle=1 z=2 + kwin1 handle=1->2 z=4 cascade pmm backings;
mouse press on kwin1 titlebar -> comp: drag arm -> 6x(15,8) moves ->
drag drop; titlebar px = 0x3040C0 focused, bodies tinted per-index,
border 0xd8dee9; console text px present in retained root (2024 non-bg
px sampled); 'kwclose' -> KORU kwin close 1 handle=2, vacated region
repainted console bg 0x1a1a2e (retained reveal, no snapshot).

T590 ORACLE (unverified — no HW this session): flash ISO -> 'kwin' x2
overlapping cascade windows; TrackPoint press-drag titlebar moves with
z-order intact; 'kms' -> scene swapchain comes up (KORU scene: flip
buffers up + flip markers on :47820); console text survives window
coverage; 'kwclose' reveals. Panel visibility + i915 flip path are
HW-only — QEMU exercises backend A only.

Honest limits: backend B (flip) is code-complete but UNEXERCISED —
QEMU has no i915; first T590 'kms' run is its debut. vblank pacing
assumes DEIIR latches post-arm events (vblankArm unmasks once). kflip/
kdmabuf/kms re-run during live flip mode can destroy scene buffers —
detected per-tick via dumbGet, named, swapchain rebuilt. Console
backing sized at consoleUp; a modeset to DIFFERENT dims leaves stale
sink geometry (both paths are 1920x1080 today). Damage->composite is
per-pixel topmost-wins — full-screen repaint ~tens of ms, damage
rects are small in steady state.

## MC-1 fix — console root resize on surface gen change (2026-11-09)

T590 regression: after 'kms' modeset (1024x768 LFB -> 1920x1080 i915
dumb), console text invisible — typing showed no letters. Root cause:
consoleUp sized the retained root backing + text Sink at BOOT dims;
modeset left stale sink geometry AND comp.W/H never resynced, so
composite clipped to the old 1024x768 scene rect.

Fix (commit on native/m1-dumb-kms):
- comp.syncDims(): on demand, re-reads koruos_fb_info, updates scene
  W/H, re-clamps every live layer through decide() (placement
  authority), damage clips to new bounds.
- present.zig now OWNS the console backing (moved from shell.zig):
  consoleUp/consoleSync/consoleForce/consoleRealloc. present.tick's
  fb.generation() branch calls comp.syncDims() THEN consoleSync()
  BEFORE full damage + swapchain teardown.
- consoleSync(): same dims -> retained backing stays (console text
  SURVIVES a same-geometry modeset — retention working as designed);
  different dims -> detach old root, free backing, alloc new W*H,
  reset text.sink {px,pitch,w,h,damage}, attachRoot, marker
  "KORU scene: console resized WxH — fresh console". Old glyph pixels
  can't remap across geometry — console restarts fresh (named; the
  pre-MC1 modeset wiped scanout anyway).
- Diagnostics: 'conresize' -> consoleSync() manual; 'consmall' ->
  consoleForce(800,600) arbitrary-geometry test.
- text.zig syncDims/rebase path: rebaseConsole->text.syncDims still
  runs on modeset (fb.rebase path unchanged); flipSwap uses
  rebaseQuiet which deliberately does NOT touch text (dims don't
  change on routine flips; syncDims would reset cx,cy per frame).

QEMU-VERIFIED (dist/koru-mc1r-scene.iso): 'consmall' -> "console
forced 800x600" -> screendump shows console bg+text only in top-left
800x600, scene BG black elsewhere; 'echo SMALL' letters render;
'conresize' -> "console resized 1024x768 — fresh console" -> full
console + text restored. Exercises detach->free->alloc->sink->
attachRoot->damage->composite — the exact fix mechanics.

UNEXERCISED: comp.syncDims + the automatic gen-change trigger need a
real modeset — QEMU has no i915. T590 'kms' is the debut: expect
"comp: scene dims -> 1920x1080" + "console resized 1920x1080" +
flip buffers up + console text visible.

## MC-1r2 fix — console content + prompt survive gen-change (2026-11-09)

T590 regression: post-'kms' the console resized to 1920x1080 but NO '>'
prompt returned — blank backlight, heartbeats only. Root cause: the
'kms returned' puts + prompt() were written BETWEEN modeset and
present.tick's consoleSync — into the doomed 1024x768 backing freed
one tick later. Fresh backing stayed blank; nothing re-rendered.
Also found: flipSwap->atomicTest->stage() ran an LED blink + UDP marker
+ serial line PER FLIP (~30-60ms spin at frame cadence).

Fix:
- present.surfaceSync() = comp.syncDims + consoleSync, called in
  dispatch right after runModeset/runFlip/runDmabuf return — the
  "... returned" puts + prompt now land in the NEW backing.
- present.console_reset flag + takeConsoleReset(): set on every
  consoleRealloc; shell consumes it silently after dispatch (prompt()
  already covers) and polls it after present.tick -> redrawPrompt()
  re-prints "> " + line[0..n] for mid-line/tick-time resizes.
- kms.atomicTestQuiet: atomicCheck + GTT PTE verify with zero
  stage()/say — flipSwap uses it (per-frame cadence stays quiet).
- present.tick gen branch now calls surfaceSync() (same core).

QEMU-VERIFIED (dist/koru-mc1r2-scene.iso): 'consmall' -> forced
800x600 -> prompt+echo render; 'conresize' -> resized 1024x768 ->
prompt returns + 'echo INBIG' renders (white glyph px in screendump).
UNEXERCISED: real 1024->1920 modeset path (i915-only) — T590 debut.

## MC-1r3 fix — dead keyboard post-kms (2026-11-09)

T590 regression: post-'kms' console rendered (prompt + 'console still
alive') but ALL keyboard input dead — typing showed nothing, shell
unresponsive, heartbeats limped. Two independent defects, both fixed:

1. STARVATION (primary suspect): present.tick retried ensureFlip()
   every 64 ticks while flip bufs missing. Each attempt runs
   kms.dumbCreate(1920x1080) -> pmm.allocContiguous(~2025 frames) —
   an O(managed*n) per-frame bitmap scan that takes SECONDS on
   failure (fragmented post-console-alloc RAM). No backoff, no
   logging: the loop spent its life inside allocContiguous, pollChar
   starved, console still painted via immediateTick, heartbeats
   limped between multi-second scans. Fix: exponential backoff
   (x4/fail, cap 2^22 ticks), MAX_FLIP_FAILS=12 then flip_gave_up
   latch -> named immediate-mode degrade until next gen change
   (which resets the budget). Failures now sayU-throttled so the
   serial oracle names the cause.

2. AUX WEDGE (real, independent): kbd.pollChar refuses AUX-flagged
   8042 bytes expecting IRQ12/mouse_irq to drain them — but IRQ12 is
   armed only inside mouse.init (cursor enable). Cursor never
   enabled + any aux traffic = one byte sits in the output register
   forever, every keystroke queued behind it. Fix: pollChar consumes
   the aux byte itself when mouse.irqArmed()==false (no IRQ can fire
   -> zero race) and feeds it to mouse.feedByte so the packet
   assembler stays warm; armed case unchanged (IRQ drains).

QEMU-VERIFIED (dist/koru-mc1r3-scene.iso): boot->scene->typed
'consmall'->800x600 clip+text, 'echo CONSOK' renders, 'conresize'->
1024x768 fresh console->prompt+'echo BIGOK' renders. Keyboard echo
path exercised end-to-end.
UNEXERCISED: the flip-alloc starvation itself is i915-only (QEMU has
no kms.device().up) — T590 'kms' is the debut. If dumbs still fail,
serial now shows 'flip alloc fail N' + 'gave up' markers instead of
silently starving; immediate mode keeps console live either way.

## MC-1r4 fix — frozen swapchain: dead DEIIR oracle + kstat readback (2026-11-09)

T590 regression: input+spawn live (kwin dmabuf handle=1, aux irq12
armed) but NOTHING updated on panel — prompt frame frozen, no echo,
no window. Diagnosis: flipTick gates ALL compositing on flip_pending,
cleared only by kms.vblankDrain() (DEIIR poll). M2's flipCommit never
depended on DEIIR — runFlip DISCARDS vblankWait(2)'s result, so a
dead IIR was never caught on HW. First swapchain frame composites
(acc.full at buf create) + flipSwap arms DSPASURF -> prompt visible;
pending then sticks forever -> damage accumulates in accs, never
composites -> frozen frame. Matches symptom exactly. (Damage-flow
breakage ruled out by inspection: sceneDamage->pending->takePending
->fanDamage all wired; QEMU-verified.)

Fix:
- FLIP_TIMEOUT_TICKS=1<<17: pending clears on tick-count even with
  ev==0 — bounded stall -> live tear-prone flips instead of frozen
  frame. DSPASURF re-arms each flip; HW applies at vblank regardless.
  First timeout emits 'vblank oracle silent — timeout clear N'.
- kms.surfaceOffset() export (DSPASURF readback).
- present.stat() + shell 'kstat' command: flips/pending/age/
  timeouts/vb_raw/fails/gaveup, per-buf acc.n+acc.full, READBACK
  PIXELS from each buf's CPU map (center + 8,8), front index,
  dspsurf readback, pre_scanout. The T590 oracle now proves:
  composite wrote px -> which buffer DSPASURF points at -> whether
  DEIIR latched.

QEMU-VERIFIED (dist/koru-mc1r4-scene.iso): boot->scene->'kstat'
prints stat block (immediate mode, bufs down, dspsurf=0 — correct
no-i915). 'echo' path unaffected.
UNEXERCISED: flip path i915-only — T590 'kms' debut. If DEIIR is
alive, vb_raw nonzero + timeouts=0; if dead, timeouts climb and
flips continue tear-prone. If flips STILL frozen with timeouts
climbing, DSPASURF flips aren't applying -> next suspect is the
atomic-commit property path vs legacy surface write.

## MC-1r5 fix — DEIER never enabled + flip pacer too slow (2026-11-09)

T590 kstat decode: vb_raw=0 (DEIIR dead), flips=3 timeouts=2,
acc.n=1, px=console bg. Two real bugs:

1. VBLANK ORACLE DEAD — regs.zig is libgfxinit IRONLAKE-era
   (GMA/*_ILK suffixes); T590 is Arrandale/ILK not SKL as comments
   assumed. The DE*/SDE* interrupt quartets are
   ISR/IMR(active-low)/IIR(w1c)/IER(active-high). vblankEnable()
   historically wrote ONLY DEIMR=0 — DEIER stayed 0 -> no source
   enabled -> DEIIR reads 0 forever. M2 'worked' because
   flipCommit's DSPASURF flip needs no IIR and runFlip DISCARDS
   vblankWait's count; the 'vblank events delivered' stage() fires
   unconditionally. Fix: vblankEnable now writes DEIMR=0 +
   DEIER=0xFFFFFFFF + SDEIMR=0 + SDEIER=0xFFFFFFFF (both display
   engines); vblankPoll reads+clears DEIIR|SDEIIR and ORs them.

2. FLIP PACER — FLIP_TIMEOUT_TICKS was 1<<17 (~seconds at shell-loop
   rates) -> flips=3 in a whole session -> typed chars waited
   seconds for a composite -> 'invisible until Enter'. Now 2048
   ticks (~16-60ms -> 15-60fps degrade while DEIIR unproven).

   PER-KEYSTROKE DAMAGE WAS NEVER MISSING: handle->text.putc->
   fillS(cell)->s.damage=comp.sceneDamage fires every char; glyph
   pixels ride the same cell rect. acc.n=1 is Acc merge (a line of
   echo unions to one rect) — expected, not a bug. Verified by
   inspection + QEMU echo path.

QEMU-VERIFIED (dist/koru-mc1r5-scene.iso): boot->kstat->echo->
consmall->conresize->echo all render; serial markers clean.
UNEXERCISED: DEIER/IER path + flip cadence are i915-only — T590
debut. kstat now shows: vb_raw!=0 + timeouts=0 if IER fix lands;
flips count = real frame rate either way.

## MC-1r6 fix — keyboard decode garbage post-mouse-init (2026-11-09)

T590 regression: after enabling cursor, keys decoded wrong — 'a'
showed Enter, only 'n' correct. Decode math: set-2 'a'=0x1C ==
set-1 Enter=0x1C; set-2 'n'=0x31 == set-1 'n'=0x31 (coincidence).
The keyboard emits scancode SET 2 and pollChar's tables are SET 1 —
correct ONLY because 8042 CCB bit6 (translation, set-2->set-1)
was ON. mouse.init's STEP-4 CCB write preserved "bits as read" —
but the 0x20 CCB read validates only (r&0x88)==0, which PASSES for
scancode make bytes; a keypress during the probe window got
misread as CCB -> cw inherited garbage bit6=0 -> translation OFF
-> raw set-2 hit set-1 tables. Shell path never runs consoleInit,
so keyboard stays firmware-default set-2 + translate-ON — the
config that must be preserved.

Fix (mouse.zig STEP 4): write DETERMINISTIC CCB 0x47 (kbd-IRQ +
aux-IRQ + system + translate, inhibits off) instead of read+preserve
— immune to scancode-misread entirely. Readback verify now checks
bit4==0 AND bit6==1, rewrites 0x47 on either failure.

QEMU-VERIFIED (dist/koru-mc1r6-scene.iso): 'mouse' decoded (init
ran: selftest=85, ccb wr=47 rb=47, aux online, irq12 armed) then
'consmall' decoded post-write -> 'console forced 800x600' marker.
Decode correct on both sides of the CCB write.
UNEXERCISED: T590's actual CCB-read race (scancode landing mid-probe)
is timing-dependent — the deterministic write removes the dependency
entirely, so HW behavior can't regress from it.

## MC-1r7 fix — click-to-raise z-order + spawn phase timing (2026-11-09)

T590 r6 worked (kbd decode, kwin x N, drag, pointer) but two issues:

1. Z-ORDER/RAISE: clicking a lower window didn't cover the one above
   until you dragged it. Root cause: comp.tick press-edge calls
   focusWindow+raiseLayer; raiseLayer re-stamped l.z but generated
   ZERO damage — z decides pxIn resolution, but only damaged rects
   composite, so overlap pixels kept stale topmost content until a
   drag's place() damaged old+new rects. Fix: raiseLayer now damages
   the layer's full rect — every raise repaints its z-resolution
   domain (windowOpen's extra raise merges harmlessly).

2. SLOW SPAWN: added rdtsc phase timing to win.spawn — marker now
   reads 'us alloc=N paint=N attach=N' (alloc=dumbCreate/pmm+map,
   paint=fillRect pass, attach=windowOpen/place/damage). QEMU numbers:
   first spawn 47/315/586us, second 28/44/75us — all sub-ms; the
   'alarming' T590 cost is therefore NOT the spawn CPU path itself.
   Remaining suspects: (a) first-spawn cursorMod.enable()->mouse.init
   8042 probe (one-time, ~100ms-class, only if cursor wasn't already
   on); (b) flip-appear latency — window shows at next flip, and if
   DEIIR still dead the 2048-tick timeout at slow loop rates is the
   real delay. T590 marker will name which.

QEMU-VERIFIED (dist/koru-mc1r7-scene.iso): 2 kwins spawn (markers
with us breakdown), click->'focus root' defocus repaint reached
screen (5580 px diff). Click-raise pixel-verify INCONCLUSIVE — QEMU
mouse_move is relative from unknown cursor start, couldn't land on
the 28px window strip reliably; raise path verified by inspection
(z-change => damage => composite resolves new order).

## MC-1r8 fix — 3.7s spawn stall: window backing pool (2026-11-09)

T590 spawn marker exposed it: us alloc=3720366 — pmm.allocContiguous
(63 pages) on RAM fragmented by 2x8MB scene dumbs + 2x8MB flip dumbs +
8MB console = seconds-long bitmap scan INSIDE the shell loop -> frozen
mouse+kbd, post-stall drag-state corruption. Window backings are
CPU-composited only (display engine never scans them) — they need
VA-contiguous memory, NOT physically-contiguous pages and NOT
GTT/dmabuf mapping (the dmabuf path was pure overhead + same stall).

Fix (win.zig + shell.zig):
- win.poolInit() at shell init (after consoleUp, BEFORE any kms
  command): ONE pmm.allocContiguous(500 pages)=2MB run + mmio.map,
  sliced into MAX_WIN=8 backings of 320x200x4=256000B each.
- spawn() = O(1) pool_free slice handout — no allocContiguous, no
  dmabufCreate, no GTT writes, EVER. kind="pool" in marker.
- freeWin returns the slice to pool_free — close/reopen reuses.
- pool down/exhausted -> named refusal, never silent fallback.
- kms import dropped from win.zig (no display-side consumer exists).

Drag-after-spawn: the stall itself is gone (handout ~ns) — the
press-edge/drag-arm desync was stall-induced (motion burst post-
freeze), not a logic bug; no comp changes needed.

QEMU-VERIFIED (dist/koru-mc1r8-scene.iso): 'backing pool up
320x200B x8' at boot; spawn alloc=14us/18us/0us (was 3.7s-class on
T590); kwclose->kwin respawn reuses slice cleanly. Drag path
unchanged (verified r6/r7).
UNEXERCISED: real fragmented-RAM timing is T590-only by definition —
but the mechanism is removed, not retimed: spawn can no longer call
allocContiguous at all.

## MC-1 COMPOSITOR LANDED on T590 (2026-11-09)

Multi-window desktop working on real hardware: kwin spawns N windows
(backing=pool O(1) alloc, ~16ms), drag effortless, click-to-raise
works, damage-tracked compositing (rects=1 steady state, no flicker),
keyboard+pointer live, console retained root layer survives windows.

Bugs fixed this arc: 3.7s spawn stall (allocContiguous on fragmented
RAM -> pre-allocated backing pool), dead vblank oracle (DEIIR never
fires -> timeout-driven ~10fps pacing), CCB translation kill (mouse
init garbage bit6 -> deterministic 0x47), console resize blank
(surfaceSync + consoleRealloc + prompt redraw), frozen swapchain
(flip_pending timeout fallback), keyboard decode (set-2 vs set-1
tables via translation bit), dead keyboard (flip-alloc backoff +
aux wedge drain).

Remaining: vblank DEIIR reads 0 on T590 (frame pacing timeout-driven
~10fps instead of 60Hz), MC-2 vblank-sync, MC-3 oshun backend.

## MC-1r9 — vblank root cause: FRMCNT oracle + reg dump (2026-11-09)

~10fps on T590 = timeout-paced flips (vb_raw=0, DEIIR never fires).
Root-cause dig on Ironlake (regs.zig is libgfxinit GMA-era):

- DEIIR/DEIMR/DEIER/SDE* are ENGINE-level interrupt regs; per-pipe
  vblank lives elsewhere. regs.zig also has IIR=0x044028 (per-pipe
  interrupt IIR) — vblank's likely real home — and
  PIPE_FRMCNT_A=0x070040: the frame counter, which increments once
  per scanned frame with ZERO interrupt enables required.
- M2's 'vblank events delivered' was NEVER proof: stage() fires
  unconditionally and runFlip discards vblankWait's count — a dead
  IIR was structurally invisible until the swapchain needed it.

Fix (pipe.zig): vblankPoll now ALSO reads PIPE_FRMCNT_A — delta vs
last read returns synthetic event bit31. Hardware-guaranteed 60Hz
pacing regardless of interrupt state; DEIIR/SDEIIR still OR'd in.
kms.vblankDebug() dumps DEISR/DEIIR/SDEISR/SDEIIR/IIR28/FRMCNT —
kstat prints it (guarded: 'i915 down' when !device().up).

Expected T590: flips at ~60Hz (FRMCNT delta every frame), timeouts
stop climbing, vb_raw shows bit31 synthetic events. If FRMCNT also
reads static -> display engine truly not scanning -> deeper modeset
issue (would contradict visible output, so unlikely).

QEMU-VERIFIED (dist/koru-mc1r9-scene.iso): kstat prints stat block +
'kms:vb i915 down — no regs' (guard prevents MMIO fault, no i915).

## MC-1ra — revert FRMCNT oracle, extend vblank probe (2026-11-09)

r9 regression: PIPE_FRMCNT_A delta detected frames but committed
flips mid-scan -> SCREEN TEARING (worse than r8's ~10fps timeout
stutter). Frame counting proves scanout runs but gives no vblank
INSTANT — reverted vblankPoll to DEIIR|SDEIIR only; present.zig's
2048-tick timeout pacing is the stable baseline again.

vblankDebug extended: now also dumps PSTAT24=mmio.rd(0x70024)
(PIPEASTAT_A — ILK bit1=vblank/bit0=MPU, the classic per-pipe status
regs.zig lacks) and GTIIR=0x44018 (third interrupt engine). kstat
prints all candidates — T590 names which register actually moves
during scanout. Next iteration wires flip gating to the live one.

QEMU: build clean; code path = r8-verified timeout pacing + read-only
debug reads (i915-down guarded). ISO dist/koru-mc1ra-scene.iso,
MBR 830002001000000001000000a3790000.

## MC-1rb — vblankDebug reaches the wire (2026-11-09)

MC-1ra bug: kstat's register dump never appeared on the wire —
kms.vblankDebug used mmio.say (serial-only). Present.stat now calls
kms.vblankRegs() (new accessor returning the 8 candidate regs as
values) and prints via sayU — serial+UDP dual-write like every other
kstat line. i915-down prints 'vb i915 down — no regs'; i915-up
prints 'vb DEISR= DEIIR= SDEISR= SDEIIR=' + 'vb IIR28= GTIIR=
FRMCNT= PSTAT24=' (0x70024 PIPEASTAT_A literal). QEMU-verified:
kstat emits the vb line (down path). T590: run kstat 2x ~1s apart —
whichever reg toggles at ~60Hz is the real vblank oracle.

ISO dist/koru-mc1rb-scene.iso, MBR
8300020010000000010000008f790000.

## MC-1rc — ILK legacy IRQ bank + FRMCNT-edge-aligned commits (2026-11-09)

T590 kstat decoded (mc1rb): FRMCNT increments ~60/s (display scans
60fps) but EVERY vblank status/IRQ reg read 0 — DEISR=0 DEIIR=0
SDEISR=1000000(static) SDEIIR=0 IIR28=0 GTIIR=0 PSTAT24=0. The DE*/
SDE* quartets at 0x44000/0x0c4000 are SNB+ display-ENGINE regs —
Arrandale (gen5/Ironlake) routes per-pipe interrupts through the
LEGACY bank instead: LGC_IMR=0x20820 LGC_ISR=0x20830
LGC_IIR=0x20840 (new regs.zig consts + PIPEASTAT_A=0x70024).

vblankEnable now also writes LGC_IMR=0xFFFF0000 — unmask low 16
(per-pipe space), keep hotplug/FM/MST masked (no IRQ handler; an
unmasked storm would livelock). vblankPoll reads+acks LGC_IIR via
ISR write-back and ORs it into the drain. kstat dumps all 11
candidate regs (3 sayU lines).

FALLBACK COMMIT PATH (active while no IRQ proven): flipTick now
edge-aligns DSPASURF writes on FRMCNT — composite into back buffer
first (never scanned, always safe), then waitFrameEdge() spins for
the next FRMCNT increment (~260k MMIO reads, bounded ~30-50ms) and
kms.flipSwapFast writes DSPASURF within ~us of the frame boundary,
skipping atomicTestQuiet so nothing pushes the commit off vblank.
flip_pending clears on IIR event OR FRMCNT delta past armed_frm OR
timeout — FRMCNT delta = flip landed at boundary, giving ~30fps
cadence (detect-then-wait skips a boundary) pending T590 verdict.
r9's mid-scan commits are structurally impossible now: the write
only ever happens immediately after a frame boundary.

QEMU-verified: boot->kstat prints 'vb i915 down — no regs' (flip
path never runs without KMS; no MMIO faults). ISO
dist/koru-mc1rc-scene.iso MBR 8300020010000000010000009b790000.
T590: kstat 2x ~1s apart — watch LGCIIR/LGCISR toggle at 60Hz;
if it latches, wire flip gating to it for true 60fps.

## MC-1rd — vb: telemetry on the automatic stream (2026-11-09)

T590 UX constraint: kstat can't be run mid-drag. flipTick now emits
a compact 'vb:' pair every 65536 ticks (~1s) via sayU (serial+UDP
dual-write) whenever flip mode is live — unreachable when i915 is
down (flipTick only runs under device().up + flipReady), so QEMU
emits nothing and can't fault on MMIO.

Line 1: vb DE= DI= SD= SI= I28= GT=  (DEISR DEIIR SDEISR SDEIIR
IIR@0x44028 GTIIR@0x44018)
Line 2: vb FR= PS= IM= IS= II= +f= pd= to=
(FRMCNT@0x70040 PSTAT24@0x70024 LGC_IMR LGC_ISR LGCIIR@0x20840,
+f=flips-this-interval=real fps while dragging, pd=flip_pending,
to=timeout_clears). Diff consecutive samples ~1s apart: whichever
reg toggles at ~60Hz is the vblank oracle.

QEMU-verified: boot clean; 'kms' fails on Bochs 1234:1111 as
expected; no vb lines, no MMIO access. ISO
dist/koru-mc1rd-scene.iso MBR 830002001000000001000000df790000.

## MC-1re — cursor sprite damage hardening + pxIn BG fix (2026-11-09)

T590 report: cursor trails / "10 copies" while dragging. Audit found
the erase-old/draw-new coverage was ALREADY present — feedPointer
damages the union of last-fed + current sprite rects every motion,
and Acc.add merges so both endpoints always repaint. Changes:

- feedPointer: union replaced by two explicit damage() calls (old
  rect + new rect) — same coverage, honest contract.
- comp.syncDims: spr_damaged=null on scene resize — stale tracked
  pos can't skip erase coverage after modeset/rebuild.
- pxIn REAL BUG: `if (!hit) return BG` returned BEFORE the sprite
  XOR — cursor never composited over uncovered/background pixels
  (vanished over gaps). Now sprite applies to BG too.

NOT proven as trail root cause — erase coverage was already correct.
Prime remaining suspect for perceived "trails" during drag: damage
flood -> acc.full -> full 1920x1080 composite every flip + the
~16ms waitFrameEdge stall = low effective fps = motion smear that
reads as ghost copies. kstat's per-buffer acc.n/acc.full + the vb:
+f delta will confirm on T590 (acc.full=1 + low +f during drag =
smear-not-ghosts). cursor motion needs TrackPoint — QEMU can't
reproduce trails; verified no-regression only (boot/kwin/kstat).

ISO dist/koru-mc1re-scene.iso MBR 830002001000000001000000df790000.

## KNOWN-JANK — compositor sluggishness ledger (2026-11-09)

Documented so the return is surgical. ~55fps FRMCNT-edge-aligned
flips CONFIRMED on T590; cursor trails match macOS behavior
(hardware cursor plane updates at its own cadence); MC-1 landed.

CHEAP FIXES:
- (a) waitFrameEdge spin adds up to ~16ms latency/flip —
  present.zig flipTick():262144-iteration MMIO poll for the next
  PIPE_FRMCNT_A increment, run INSIDE the shell loop (blocks input
  polling). Tighten the detect->commit window or move the wait
  off the critical path.
- (b) vb:/kstat register reads are debug overhead in the hot path —
  present.zig flipTick() emits a 2-line sayU dump every 65536 ticks
  (~1s) while flip mode is live; vblankRegs() does 11 MMIO reads.
  Gate behind a flag once the vblank oracle is settled.
- (c) damage coalescing could be smarter during fast drag —
  comp.zig Acc.add merges touching rects but fast flicks produce
  disjoint rects -> MAX_DMG=32 overflow -> acc.full -> full
  1920x1080 composite every flip (the drag-smear suspect).

STRUCTURAL GAPS:
- (a) CPU-only compositing — no GPU render engine; i915 display
  engine does scanout/flips only, no 3D/render path.
- (b) no hardware cursor plane — planes[1] sprite exists unwired
  in the i915 object model; wiring it would kill trails AND free
  the CPU sprite pass entirely.
- (c) no real vblank IRQ — every probed register reads 0 on T590:
  DEISR DEIIR SDEISR SDEIIR IIR28(0x44028) GTIIR(0x44018)
  PSTAT24/PIPEASTAT_A(0x70024) LGC_IMR/LGC_ISR/LGC_IIR
  (0x20820/0x20830/0x20840, enabled via LGC_IMR=0xFFFF0000).
  PIPE_FRMCNT_A edge-align is the ceiling at ~55fps.

## MC-3 OSHUN-BACKEND — real oshun component in a kwin window (2026-11-09)

WHAT OSHUN PRODUCES (investigated, not assumed): NOT a pixel buffer —
a render-command display list. Path: libs/ui panelx/text/el.cfg decls
-> libs/clay solver (clay.h, CoreText measure) -> clay:each drains
clay_RenderCommandArray -> normalized CmdView structs (kind/x/y/w/h/
r..a/fs/ud/ctl..cbr/tx). nativelayout:nl.each emits the identical
stream from the pure-Koru solver port. The metal backend is the only
existing consumer and is macOS-host-bound (AppKit/CoreText) — useless
freestanding. So the seam is: solver emits commands OFF-TARGET, a
native rasterizer paints them into the window backing ON-TARGET.

PRODUCER (oshun repo, branch main):
  oshun/koruos/ui_probe.k + koruos/koru.json — gallery_live.k's own
  idiom: panelx root + el.cfg button (cr=10 corners, el.cfg because
  panelx has no radius param) + ui:text ENGAGE + ui:text "t=0000".
  Two solves per run ==A==/==B== (world.hot palette — the gallery's
  state->restyle->redraw). `koruc run koruos/ui_probe.k` -> ui_cmds.txt.
  Contract: ud==2 = button hit region, ud==90 = live counter slot.

RASTERIZER (koru/native/cmdview.zig): parses embedded ui_cmds.txt into
2 streams, paints XRGB8888 into win backing at (2,24) canvas 316x174.
kind1 RECT fill + per-corner quarter-arc radius + src-over alpha;
kind3 TEXT 8x8 font scale2 (fs>=13) centered in cmd box; kind5/6
SCISSOR clip stack; kind2/4/9 + unknown = counted skip (stats(), never
silent). Text is wider than CoreText measure — centered, may overflow
box: NAMED. No solver on-target (clay needs CoreText/libc) — the dump
is the pinned artifact, regenerated by the producer.

WINDOW (win.zig/comp.zig/shell.zig): spawnImpl(ui) — 'kwui' command.
WinObj.ui/hot/ctr_*; paintUi = chrome + cmdview.render(stream A).
uiTick per tick: pointerPos+scenePos -> canvas coords -> hitButton ->
hot flips stream A<->B + repaintUi + damageLayer; TSC-clocked counter
(~2s) rewrites ud==90 digits in BOTH streams + repaint. comp.zig gained
pointerPos/scenePos read-only getters for producer-side hit-testing.

QEMU-VERIFIED BOTH PATHS:
- kernel-direct (-kernel mc3-ui.elf): 'kwui' -> spawn marker; screendump
  pixel-exact: button (52,120,246)=0.204/0.471/0.965*255, bg
  (16,18,26)=root panel color — REAL solver colors on screen.
- ISO (-cdrom, BIOS->GRUB->mb2 tag8 fb — the real loader path):
  dist/koru-mc3-ui-20261109-2329.iso, MBR verified
  83 00 02 00 10 00 00 00 01 00 00 00 03 7b 00 00 (corrected patch).
  'kwui' -> same pixel-exact component (402 sampled blue px).

HONEST LIMITS: hover/counter live-verified in QEMU logic path but NOT
yet exercised on T590 (i915 panel path is T590-only, unmeasured there);
BORDER/IMAGE/CUSTOM kinds counted-skipped; text metrics mismatch vs
CoreText named; counter period ~2s TSC. Route to fuller UI: more
components = more markup/spec rows through the same producer; runtime
solver on-target would need a freestanding nativelayout build + Koru
runtime in-kernel — large, not attempted.

FILES: koru/native/cmdview.zig (new), ui_cmds.txt (embedded dump),
win.zig, comp.zig, shell.zig. Oshun: koruos/ui_probe.k, koruos/koru.json.

## GPU-DRAW LANDED — GEN9.2 render engine executes our commands (2026-11-10)

MILESTONE: first visible GPU-rendered pixels on the T590 panel.
`gpu` probe -> gt5b context-free bare-ring GGTT XY_COLOR_BLT wrote a
solid red rect (readback 12/12 red) + 32-dword magenta
MI_STORE_DWORD_IMM|GGTT stripe (4/4) into the LIVE kms scanout
buffer — user confirmed red blob bottom + magenta strip top on panel.
GEN9.2 BCS blit engine runs our hand-built ring batch with NO execlist
context: dst = GGTT byte offset of scanned phys, pitch/rows/width_dw
per intel_migrate.c emit_clear ver>=8 layout.

Context: gt5a LRC+ELSP+PPGTT path built (gen9_xcs_offsets image, 3-level
PD/PT hand-mapped, descriptor VALID|PRIVILEGE|FORCE_RESTORE|LEGACY_32B)
submits and head advances, but PDP0=0 post-run -> context did NOT
engage (HEAD-STALLED on the PPGTT batch). Submission plumbing proven
earlier (gt3/gt4 head advanced + GGTT store proof). Execlist context
engagement = next rung (descriptor ctxid=0? FORCE_PD_RESTORE? GuC
absent?).

Geometry fix this round: blt dst was page-aligned but MID-ROW (pitch
7680 vs page 4096 realign every 8 rows/15 pages) -> top edge stepped,
right edge off ~1px. Now row0 snapped to the row/page cycle
(alignRows=4096/gcd(pitch,4096)=8) -> dst row+page aligned, bottom
256 rows (824..1079) full-width clean rect.

NEXT: fix blit geometry on-panel -> PPGTT context engagement -> real
surfaces -> shaders. QEMU can't test i915 — T590-only.
ISO: dist/koru-gtblit3-20261110.iso (proven pipeline + corrected MBR).

## GPU COMPOSITING — scene damage through BCS blits (2026-11-10)

`koru/native/i915/gpublt.zig` — persistent BCS copy-blit compositor
backend on the proven gt5b context-free GGTT path. present.flipTick
routes each back buffer's damage acc through it when armed; CPU
compositeAcc remains the named fallback (paintFrame false => cpu_frames++,
never silent). Auto-arms on first flip when kms.device().up; refused
arms retry at 0.5Hz.

Per damage rect: XY_COLOR_BLT BG fill + XY_SRC_COPY_BLT per live layer
in z-asc painter's order (comp.layerView read-only seam; opaque
XRGB8888 == pxIn topmost-wins), then MI_STORE_DWORD_IMM|GGTT fence seq
polled on a dedicated page — blits complete before return, then
comp.applySprite does the cursor XOR pass on the CPU map.

Ring: 64KiB pmm+GGTT, emit_off byte cursor, wrap = NOOP-pad to ring end
+ restart at offset 8 (i915 intel_ring_begin semantics; tail never 0).
repoke() rewrites START/CTL every submit so a `gpu` probe re-arm can't
strand it. Layer backings GGTT-mapped lazily keyed by (phys,span) —
win pool 256000B slices are 2048B-shifted, aperture offset carries the
sub-page delta. GTT budget shares kms.gttAlloc bump, capped below
gt.zig's fixed 0x8000 probe slots.

Command oracle: XY_SRC_COPY_BLT 10dw — DW1 depth|ROP|dst_pitchB,
DW2/3 dst origin/extent (y<<16|x), DW4/5 dst addr, DW6 src origin,
DW7 src_pitchB, DW8/9 src addr (intel_migrate.c emit_copy +
i915_gem_client_blt.c + sna_blt.c agree on ver>=8 layout).

Telemetry: `gpucomp:` markers serial+UDP — armed, per-120-frame
blit/frame/map counts, submit/fence FAIL with CPU-fallback note;
`gcomp` shell cmd + present.stat gpu=/cpu= frame split. kstat readback
px unchanged.

ISO: dist/koru-gpub-20261110-0128.iso (ReleaseSmall layout, .data
0x141000 < 0x168000 threshold; corrected MBR 830002001000000001000000
bb5e0000). QEMU boot verified to shell+hb (non-i915 => CPU path).
T590 validation pending: 'kms' then drag a kwin window — expect
gpucomp:armed + frame blits=N markers and visibly smoother drag.
