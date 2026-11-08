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
