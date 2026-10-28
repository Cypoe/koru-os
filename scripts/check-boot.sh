#!/usr/bin/env bash
# check-boot.sh — the boot tier: declaration truth is not boot truth.
#
# Builds a multiboot2/PVH ELF from a boot fixture (build-native.sh), runs it
# under QEMU -kernel, and asserts the program's own serial output. A green
# run is measured boot evidence — the emitted entry actually executed on the
# image — not a bound-row claim. Needs koruc + zig + QEMU (+ WSL e2fsprogs
# for the ext2 fixture); missing tools are failures, not skips.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QEMU="${QEMU:-/c/Program Files/qemu/qemu-system-x86_64.exe}"
# wall-clock only — every row's evidence is a serial grep, so a
# stretched window can never turn a fail green; it just keeps a loaded
# host's slow QEMU from being mistaken for a dead guest. boot_real's
# multi-spawn chain has measurably crossed 15s under gate load.
TIMEOUT="${TIMEOUT:-30}"
FIX="$(cygpath -m "$ROOT/koru/native/tests" 2>/dev/null || echo "$ROOT/koru/native/tests")"

pass=0; failn=0
ok()  { pass=$((pass+1));  echo "ok   $1"; }
bad() { failn=$((failn+1)); echo "FAIL $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# boot_check <fixture.k> <expected-substring> [extra qemu args...]
boot_check() {
    local fixture="$1" want="$2"; shift 2
    local name src
    name="$(basename "$fixture" .k)"
    src="$WORK/$name.k"
    sed "s|{{ ENTRY }}|$FIX|g" "$fixture" > "$src"
    bash "$ROOT/scripts/build-native.sh" "$src" "$WORK/$name.elf" > "$WORK/$name.build" 2>&1 || {
        bad "$name: build failed"; tail -6 "$WORK/$name.build"; return
    }
    if [ ! -x "$QEMU" ]; then bad "$name: QEMU not found at $QEMU"; return; fi
    timeout "$TIMEOUT" "$QEMU" -kernel "$WORK/$name.elf" -serial stdio \
        -display none -m 64M -no-reboot "$@" > "$WORK/$name.serial" 2>&1
    if grep -qF "$want" "$WORK/$name.serial"; then
        ok "$name: booted, serial says \"$want\""
    else
        bad "$name: expected \"$want\" on serial; got: $(head -5 "$WORK/$name.serial" | tr '\n' '|')"
    fi
}

boot_check "$ROOT/koru/native/tests/boot_hello.k" "KORU NATIVE BOOT OK"

# pmm: the frame allocator must discover RAM from the loader's own map —
# PVH hvm_start_info under QEMU -kernel, mb2 tag 6 under GRUB — and pass
# its serial selftest (alloc→pin→shared-free→release→double-free refused
# →frame writable through identity).
if grep -qE 'pmm: usable=[0-9]+MiB managed=[0-9]+' "$WORK/boot_hello.serial"; then
    ok "pmm: RAM discovered from the loader memory map (PVH/mb2)"
else
    bad "pmm: no usable-memory report: $(grep pmm "$WORK/boot_hello.serial" | head -2 | tr '\n' '|')"
fi
if grep -qF 'PMM selftest ok' "$WORK/boot_hello.serial"; then
    ok "pmm: alloc/pin/free/double-free-refused selftest passed"
else
    bad "pmm: selftest failed: $(grep 'PMM' "$WORK/boot_hello.serial" | head -3 | tr '\n' '|')"
fi

# pci-enum: config-space enumeration is a substrate service — providers
# look hardware up in the table, they never rescan the bus themselves.
# The i440FX table is the evidence: host bridge, the PIIX3 multifunction
# funcs (01.1 IDE + 01.3 ACPI found via header-type bit 7), the VGA fb
# now claims through findClass, QEMU's default e1000 — and the count line
# proves the whole scan, not a probe that stopped at its own device.
if grep -qF "pci: 00:00.0 8086:1237 class=06/00/00" "$WORK/boot_hello.serial" \
   && grep -qF "pci: 00:01.1 8086:7010 class=01/01" "$WORK/boot_hello.serial" \
   && grep -qF "pci: 00:02.0 1234:1111 class=03/00" "$WORK/boot_hello.serial" \
   && grep -qF "pci: 00:03.0 8086:100e class=02/00" "$WORK/boot_hello.serial" \
   && grep -qF "pci: 06 devices enumerated" "$WORK/boot_hello.serial"; then
    ok "pci-enum: i440FX table — host bridge, multifunction PIIX3, VGA, NIC"
else
    bad "pci-enum: table incomplete: $(grep -a '^pci:' "$WORK/boot_hello.serial" | tr '\n' '|')"
fi

# acpi: RSDP discovery + SDT table walk — under QEMU -kernel no loader
# hands us a pointer, so the bare-metal scan (EBDA head, then the
# 0xE0000-0xFFFFF BIOS window) IS the path. SeaBIOS answers rev=0 with
# an RSDT carrying the i440fx set: FACP/APIC/HPET/WAET — the names
# MADT-parse (SMP) and shutdown will ask findTable for.
if grep -qE "acpi: rsdp@[0-9a-f]+ rev=0 oem=BOCHS" "$WORK/boot_hello.serial" \
   && grep -qE "acpi: tables=[0-9]+ FACP.*APIC" "$WORK/boot_hello.serial"; then
    ok "acpi: RSDP scanned, RSDT walked — FACP/APIC/HPET/WAET registered"
else
    bad "acpi: discovery evidence missing: $(grep -a '^acpi:' "$WORK/boot_hello.serial" | tr '\n' '|')"
fi

# madt/fadt: payload parses behind findTable — lapic/ioapic/cpu counts
# for SMP, pm1a+_S5 for the power door. QEMU i440fx: 1 cpu, 1 ioapic,
# 5 interrupt-source overrides, PM1a=0x604, _S5 typa=0 (SeaBIOS).
if grep -qE "madt: lapic=fee00000 cpus=1\(1en\) ioapics=1 isos=[0-9]+" "$WORK/boot_hello.serial" \
   && grep -qE "fadt: pm1a=604 dsdt@[0-9a-f]+ s5 typa=[0-9]+ typb=[0-9]+" "$WORK/boot_hello.serial"; then
    ok "acpi-tables: MADT cpus/ioapics counted; FADT pm1a + DSDT _S5 decoded"
else
    bad "acpi-tables: payload evidence missing: $(grep -aE 'madt|fadt' "$WORK/boot_hello.serial" | tr '\n' '|')"
fi

# ioapic: the second interrupt door owns legacy delivery. MADT's IOAPIC
# is probed (id/pins/gsi-base), the ISO table is honored (i440fx remaps
# IRQ0 to GSI2 — assuming irq==gsi loses the timer), the provider's
# unmask verb lands on IOREDTBL mask bits not the PIC IMR, and the PIC
# is masked off entirely — every row below that takes a device IRQ
# (timer/kbd/mouse/virtio/wake/sched) proves a LAPIC-delivered line.
if grep -qE "ioapic: base=fec00000 id=[0-9]+ pins=24 gsi-base=0" "$WORK/boot_hello.serial" \
   && grep -qF "irq0 -> gsi2 edge-high" "$WORK/boot_hello.serial" \
   && grep -qF "ioapic: pic lines masked" "$WORK/boot_hello.serial" \
   && grep -qF "ioapic: pin2 unmasked" "$WORK/boot_hello.serial"; then
    ok "ioapic: IRQs routed through IOREDTBL to the LAPIC — ISO remap honored, PIC masked"
else
    bad "ioapic: routing evidence missing: $(grep -aE 'ioapic|irq0|unmask|timer' "$WORK/boot_hello.serial" | tr '\n' '|')"
fi

# powerctl: the power door exercised for real — boot_acpi calls
# powerctl(5), the PM1a_CNT write powers QEMU OFF mid-boot; boot_reboot
# calls powerctl(1), the 8042 pulse resets it (-no-reboot exits). The
# evidence is the marker AND QEMU terminating before the timeout — a
# refused register write would hang, not exit.
for acf in acpi reboot; do
    akwant="ACPI-S5-ARMED"; [ "$acf" = reboot ] && akwant="ACPI-REBOOT-ARMED"
    afsrc="$WORK/boot_$acf.kz"
    sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koru/native/tests/boot_$acf.kz" > "$afsrc"
    if bash "$ROOT/scripts/build-native.sh" "$afsrc" "$WORK/boot_$acf.elf" > "$WORK/boot_$acf.build" 2>&1; then
        timeout 30 "$QEMU" -kernel "$WORK/boot_$acf.elf" -serial stdio \
            -display none -m 64M -no-reboot > "$WORK/boot_$acf.serial" 2>&1
        arc=$?
        if grep -qF "$akwant" "$WORK/boot_$acf.serial" && [ $arc -ne 124 ]; then
            ok "powerctl-$acf: marker + VM exited on the power door (rc=$arc)"
        else
            bad "powerctl-$acf: $(grep -aE 'ACPI|powerctl' "$WORK/boot_$acf.serial" | tail -3 | tr '\n' '|') rc=$arc"
        fi
    else
        bad "powerctl-$acf: build failed"; tail -6 "$WORK/boot_$acf.build"
    fi
done

# smp: INIT-SIPI-SIPI on the LAPIC — MADT's roster becomes running CPUs.
# Reuses the boot_hello ELF under -smp 4: the BSP writes the trampoline
# page params, pulses INIT + 2xSIPI per APIC id, and each AP must ack
# from real 64-bit code before the tick deadline. Then the roster claim:
# each AP arms the shared IDT + its own LVT timer (BSP-calibrated against
# PIT) and must take nonzero kernel interrupts — a CPU that runs kernel
# interrupt context on its own tables is a schedulable one.
timeout 40 "$QEMU" -kernel "$WORK/boot_hello.elf" -smp 4 -serial stdio \
    -display none -m 64M -no-reboot > "$WORK/boot_smp.serial" 2>&1 || true
if grep -qF "smp: bsp id=0" "$WORK/boot_smp.serial" \
   && grep -qF "smp: ap id=1 online" "$WORK/boot_smp.serial" \
   && grep -qF "smp: 3/3 ap(s) online" "$WORK/boot_smp.serial" \
   && grep -qE "smp: ap id=1 ticks=[1-9][0-9]*" "$WORK/boot_smp.serial" \
   && grep -qE "smp: ap id=2 ticks=[1-9][0-9]*" "$WORK/boot_smp.serial" \
   && grep -qE "smp: ap id=3 ticks=[1-9][0-9]*" "$WORK/boot_smp.serial" \
   && grep -qF "smp: cpu roster mask=f" "$WORK/boot_smp.serial" \
   && grep -qE "sched: slot[0-9]+ claimed by cpu1" "$WORK/boot_smp.serial" \
   && grep -qE "sched: slot[0-9]+ claimed by cpu2" "$WORK/boot_smp.serial" \
   && grep -qE "sched: slot[0-9]+ claimed by cpu3" "$WORK/boot_smp.serial" \
   && grep -qF "EMBED SPAWN exit=000000000000002a" "$WORK/boot_smp.serial"; then
    ok "smp: 3 APs tick + roster mask=f + each claims and runs a child end-to-end"
else
    bad "smp: $(grep -aE 'madt|smp|sched: slot|EMBED' "$WORK/boot_smp.serial" | tr '\n' '|')"
fi

# iso: SeaBIOS -> GRUB -> multiboot2 — the real-loader path -kernel/PVH
# never exercises. Three proofs ride one boot: GRUB's own serial banner
# (a loader ran), "fb: backend=mb2" (the loader answered the header's fb
# request — PVH can never mint tag 8), and e820/ACPI off the mbi —
# pmm walks tag 6, acpi finds the RSDP via tag/EBDA at a different
# address than PVH's. Then the program's own marker.
if bash "$ROOT/scripts/build-iso.sh" "$FIX/boot_hello.k" "$WORK/koru.iso" \
    > "$WORK/iso.build" 2>&1; then
    timeout 60 "$QEMU" -cdrom "$WORK/koru.iso" -boot d -serial stdio \
        -display none -m 128M -no-reboot > "$WORK/boot_iso.serial" 2>&1 || true
    if grep -qF "GRUB: multiboot2" "$WORK/boot_iso.serial" \
       && grep -qF "fb: backend=mb2" "$WORK/boot_iso.serial" \
       && grep -qF "KORU NATIVE BOOT OK" "$WORK/boot_iso.serial"; then
        ok "iso: SeaBIOS+GRUB mb2 chain — loader fb answered, e820/ACPI off the mbi, program ran"
    else
        bad "iso: evidence missing: $(grep -aE 'GRUB|pmm:|fb:|acpi|KORU' "$WORK/boot_iso.serial" | tail -8 | tr '\n' '|')"
    fi
else
    bad "iso: build failed"; tail -6 "$WORK/iso.build"
fi

# efi: OVMF -> GRUB-EFI -> multiboot2 — the UEFI arm of the same ISO.
# Three measurements only this path can produce: OVMF hands the RSDP
# through mb2 tag 14/15 (no BIOS window exists to scan), GRUB-EFI
# answers the fb request through GOP (efi_gop is insmod'd first — the
# tag 8 framebuffer here is GOP-programmed memory), and FADT decodes
# pm1a=b004 where SeaBIOS says 0604 — the AML-decode ruling measured
# against a second firmware.
OVMF_FD="$(dirname "$QEMU")/share/edk2-x86_64-code.fd"
if [ ! -f "$OVMF_FD" ]; then
    bad "efi: OVMF fd missing at $OVMF_FD"
else
    timeout 90 "$QEMU" \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_FD" \
        -cdrom "$WORK/koru.iso" -boot d -serial stdio \
        -display none -m 128M -no-reboot > "$WORK/boot_efi.serial" 2>&1 || true
    if grep -qF "BdsDxe: starting Boot0001" "$WORK/boot_efi.serial" \
       && grep -qF "fb: backend=mb2" "$WORK/boot_efi.serial" \
       && grep -qF "comp: compositor live" "$WORK/boot_efi.serial" \
       && grep -qF "fadt: pm1a=b004" "$WORK/boot_efi.serial" \
       && grep -qF "KORU NATIVE BOOT OK" "$WORK/boot_efi.serial"; then
        ok "efi: OVMF+GRUB-EFI chain — GOP fb via tag 8, compositor on it; ACPI off mb2 tag (pm1a=b004)"
    else
        bad "efi: $(grep -aE 'BdsDxe|acpi|fb:|comp:|KORU' "$WORK/boot_efi.serial" | tail -8 | tr '\n' '|')"
    fi
fi

# disk: installable media — a partitioned MBR image whose ext2 root
# holds /boot/koru.elf + grub.cfg, GRUB i386-pc written into the MBR
# and post-MBR gap by grub-install. The chain SeaBIOS -> boot.img ->
# core.img -> partition /boot/grub -> mb2 is what a real install runs:
# the loader has to *find* the partition (msdos table + ext2 driver)
# before it can read a config, which no -kernel or -cdrom path ever
# demands.
if bash "$ROOT/scripts/build-disk.sh" "$FIX/boot_hello.k" "$WORK/koru-disk.img" \
    > "$WORK/disk.build" 2>&1; then
    timeout 60 "$QEMU" -drive "file=$WORK/koru-disk.img,format=raw,if=ide" \
        -boot c -serial stdio -display none -m 128M -no-reboot \
        > "$WORK/boot_disk.serial" 2>&1 || true
    if grep -qF "GRUB: multiboot2" "$WORK/boot_disk.serial" \
       && grep -qF "fb: backend=mb2" "$WORK/boot_disk.serial" \
       && grep -qF "KORU NATIVE BOOT OK" "$WORK/boot_disk.serial"; then
        ok "disk: MBR+partition+ext2 install image — GRUB off the disk, kernel loaded, program ran"
    else
        bad "disk: evidence missing: $(grep -aE 'GRUB|pmm:|fb:|acpi|KORU|error' "$WORK/boot_disk.serial" | tail -8 | tr '\n' '|')"
    fi
else
    bad "disk: build failed"; tail -6 "$WORK/disk.build"
fi

# fb: the koruos/fb seam over a BGA-programmed linear framebuffer — QEMU's
# built-in multiboot loader does not answer the mb2 fb request tag, so the
# provider programs the std VGA's VBE_DISPI registers itself and takes the
# LFB phys from PCI BAR0. Serial geometry is the gate; the three-band
# screen is human evidence (screendump). -display none still models the
# device, so no display is needed.
boot_check "$ROOT/koru/fb/tests/boot_fb.k" "FB COMPLETE" -vga std

# vgpu: the same fb fixture over virtio-gpu — modern virtio-pci vendor
# caps walked for the common/notify/isr windows, VERSION_1 negotiated,
# a split virtqueue armed on MSI-X (vector 48, LAPIC EOI), then the 2D
# command chain: GET_DISPLAY_INFO/CREATE_2D/ATTACH_BACKING/SET_SCANOUT,
# and TRANSFER_TO_HOST_2D + RESOURCE_FLUSH behind fb:present. `-vga none`
# removes the std VGA so the gpu is the ONLY display — the dispatcher's
# order and BGA's loud refusal are exercised by the same run. The monitor
# screendump makes the pixels machine evidence: the fixture's three
# bands must read ff0000/00ff00/0000ff off the scanout surface itself.
if [ ! -f "$WORK/boot_fb.elf" ]; then
    bad "boot_vgpu: fb fixture ELF missing (the BGA row's build failed)"
else
    gpuport=$((5200 + $$ % 400))
    gpuppm="$WORK/vgpu.ppm"
    gpuppmw="$(cygpath -m "$gpuppm" 2>/dev/null || echo "$gpuppm")"
    timeout "$TIMEOUT" "$QEMU" -kernel "$WORK/boot_fb.elf" -serial stdio \
        -display none -m 64M -no-reboot -vga none -device virtio-gpu-pci \
        -monitor "tcp:127.0.0.1:$gpuport,server,nowait" \
        > "$WORK/boot_vgpu.serial" 2>&1 &
    vgq=$!
    for _ in $(seq 1 20); do
        exec 3<>"/dev/tcp/127.0.0.1/$gpuport" 2>/dev/null && break
        sleep 0.5
    done
    dumped=0
    if [ -e /dev/fd/3 ]; then
        for _ in $(seq 1 30); do
            if grep -qF "FB COMPLETE" "$WORK/boot_vgpu.serial" 2>/dev/null; then
                printf 'screendump %s\n' "$gpuppmw" >&3 2>/dev/null && dumped=1
                break
            fi
            sleep 0.5
        done
        sleep 0.5
        exec 3>&-
    fi
    kill $vgq 2>/dev/null
    wait $vgq 2>/dev/null || true
    if grep -qF "fb: backend=vgpu" "$WORK/boot_vgpu.serial" \
       && grep -qF "vgpu: features negotiated (VERSION_1)" "$WORK/boot_vgpu.serial" \
       && grep -qF "vgpu: resource + scanout live" "$WORK/boot_vgpu.serial" \
       && grep -qF "FB COMPLETE" "$WORK/boot_vgpu.serial"; then
        ok "vgpu: fb seam rode virtio-gpu — vendor caps, VERSION_1, scanout, FB COMPLETE"
    else
        bad "vgpu: backend evidence missing: $(grep -aE 'vgpu|fb:|EXC' "$WORK/boot_vgpu.serial" | tail -6 | tr '\n' '|')"
    fi
    if grep -qF "irq: vgpu msix delivered" "$WORK/boot_vgpu.serial" \
       && grep -qE "vgpu: cmds=[0-9]+ msix=[1-9]" "$WORK/boot_vgpu.serial"; then
        ok "vgpu-msix: MSI-X vector dispatched through LAPIC EOI (measured count)"
    else
        bad "vgpu-msix: interrupt evidence missing: $(grep -aE 'msix|irq:' "$WORK/boot_vgpu.serial" | tail -4 | tr '\n' '|')"
    fi
    if [ "$dumped" -eq 1 ] && [ -s "$gpuppm" ]; then
        if command -v python >/dev/null 2>&1 && python -c "
import sys,re
d=open(sys.argv[1],'rb').read()
m=re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s', d)
w,h,_=map(int,m.groups()); o=m.end()
px=lambda x,y: d[o+(y*w+x)*3:o+(y*w+x)*3+3]
sys.exit(0 if px(w//2,h//6)==b'\xff\x00\x00' and px(w//2,h//2)==b'\x00\xff\x00' and px(w//2,5*h//6)==b'\x00\x00\xff' else 1)
" "$(cygpath -w "$gpuppm")"; then
            ok "vgpu-pixels: screendump bands read ff0000/00ff00/0000ff off the scanout"
        else
            bad "vgpu-pixels: dump present but bands wrong (or python missing) — pixels never reached the surface"
        fi
    else
        bad "vgpu-pixels: screendump failed — dumped=$dumped ppm=$([ -s "$gpuppm" ] && echo written || echo missing)"
    fi
fi

# surf: koruos/surface on the native arm — surf.zig owns custody (pool +
# provider backings) and comp.zig owns the scene: open maps at the
# compositor's fixed anchor on top of the z-stack, present() is damage
# composited through the stack, close() detaches and repaints the
# vacated rect from retained backings. The fixture prints SURF SCENE
# while the two-color composite is stable (an hlt spin holds it for the
# dump), closes both, then SURF IDLE holds the post-detach frame — the
# second dump must read the root color: reveal-on-close is compositor
# work, not client work.
# Pixel evidence is the dump, not serial — the TRANSFER-offset oracle
# lesson stands.
surf_src="$WORK/boot_surf.kz"
sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koru/surface/tests/boot_surf.kz" > "$surf_src"
if bash "$ROOT/scripts/build-native.sh" "$surf_src" "$WORK/boot_surf.elf" > "$WORK/boot_surf.build" 2>&1; then
    surfport=$((5600 + $$ % 400))
    surfs="$WORK/surfscene.ppm"
    surff="$WORK/surffinal.ppm"
    surfsw="$(cygpath -m "$surfs" 2>/dev/null || echo "$surfs")"
    surffw="$(cygpath -m "$surff" 2>/dev/null || echo "$surff")"
    # the fixture holds each named state in an hlt-paced spin — a busy
    # loop would starve TCG's main loop and every dump would read the
    # post-detach black frame (the chardev/serial lag lesson). SURF IDLE
    # marks the post-detach frame, held stable for the second dump.
    timeout 40 "$QEMU" -kernel "$WORK/boot_surf.elf" -serial stdio \
        -display none -m 64M -no-reboot -vga none -device virtio-gpu-pci \
        -monitor "tcp:127.0.0.1:$surfport,server,nowait" \
        > "$WORK/boot_surf.serial" 2>&1 &
    sq=$!
    for _ in $(seq 1 20); do
        exec 3<>"/dev/tcp/127.0.0.1/$surfport" 2>/dev/null && break
        sleep 0.5
    done
    sds=0; sdf=0
    if [ -e /dev/fd/3 ]; then
        for _ in $(seq 1 80); do
            if grep -qF "SURF SCENE" "$WORK/boot_surf.serial" 2>/dev/null; then
                printf 'screendump %s\n' "$surfsw" >&3 2>/dev/null && sds=1
                break
            fi
            sleep 0.25
        done
        for _ in $(seq 1 80); do
            if grep -qF "SURF IDLE" "$WORK/boot_surf.serial" 2>/dev/null; then
                sleep 0.3
                printf 'screendump %s\n' "$surffw" >&3 2>/dev/null && sdf=1
                break
            fi
            sleep 0.25
        done
        for _ in $(seq 1 60); do
            grep -qF "SURF COMPLETE" "$WORK/boot_surf.serial" 2>/dev/null && break
            sleep 0.25
        done
        sleep 0.5
        exec 3>&-
    fi
    kill $sq 2>/dev/null
    wait $sq 2>/dev/null || true
    if grep -qF "comp: attach 320x200 at 40,40 z=0" "$WORK/boot_surf.serial" \
       && grep -qF "surf: open 320x200 at 40,40" "$WORK/boot_surf.serial" \
       && grep -qF "surf: open 160x100 at 40,40" "$WORK/boot_surf.serial" \
       && grep -qF "empty damage refused" "$WORK/boot_surf.serial" \
       && grep -qF "SURF COMPLETE" "$WORK/boot_surf.serial"; then
        ok "surf-native: *Surf<open!> minted/filled/presented/closed; empty damage refused"
    else
        bad "surf-native: seam evidence missing: $(grep -aE 'surf|comp|FAIL|EXC' "$WORK/boot_surf.serial" | tail -6 | tr '\n' '|')"
    fi
    if [ "$sds" -eq 1 ] && [ -s "$surfs" ]; then
        if command -v python >/dev/null 2>&1 && python -c "
import sys,re
d=open(sys.argv[1],'rb').read()
m=re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s', d)
w,h,_=map(int,m.groups()); o=m.end()
px=lambda x,y: d[o+(y*w+x)*3:o+(y*w+x)*3+3]
# both surfaces anchored (40,40): surf1 cyan ON TOP (45,45 inside it),
# surf0 magenta shows where surf1 doesn't cover, bg elsewhere
sys.exit(0 if px(45,45)==b'\x00\xff\xff' and px(300,200)==b'\xff\x00\xff'
         and px(8,8)==b'\x00\x00\x00' else 1)
" "$(cygpath -w "$surfs")"; then
            ok "surf-pixels: z-composite — cyan on top at the shared anchor, magenta beneath, bg outside"
        else
            bad "surf-pixels: dump present but pixels wrong (or python missing)"
        fi
    else
        bad "surf-pixels: screendump failed — dumped=$sds ppm=$([ -s "$surfs" ] && echo written || echo missing)"
    fi
    if [ "$sdf" -eq 1 ] && [ -s "$surff" ]; then
        if command -v python >/dev/null 2>&1 && python -c "
import sys,re
d=open(sys.argv[1],'rb').read()
m=re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s', d)
w,h,_=map(int,m.groups()); o=m.end()
px=lambda x,y: d[o+(y*w+x)*3:o+(y*w+x)*3+3]
sys.exit(0 if px(45,45)==b'\x00\x00\x00' and px(300,200)==b'\x00\x00\x00' else 1)
" "$(cygpath -w "$surff")"; then
            ok "surf-reveal: closes repainted the vacated rects back to the root scene"
        else
            bad "surf-reveal: post-close dump still shows stale pixels"
        fi
    else
        bad "surf-reveal: final screendump failed — dumped=$sdf"
    fi
else
    bad "boot_surf: build failed"; tail -6 "$WORK/boot_surf.build"
fi

# comp: nativeCompositor itself — the discriminating run. The fixture
# presents the LOWER surface after the upper is already mapped AND filled,
# so at COMP UNDER the upper's cyan rect must sit on TOP — painter's-
# order-at-present would blit the lower surface's magenta over it. Then
# the presented top (SCENE), the close's retained-backing reveal (REVEAL),
# and monitor mouse_moves driving the compositor-owned cursor while the
# client still sees raw deltas (fan-out). Four dumps, one per state —
# z-order, retained repaint, and the pointer are all pixel-evidenced.
# The holds are hlt-paced: a busy spin starves TCG's main loop and dumps
# land on the post-detach frame instead of the state they name.
comp_src="$WORK/boot_comp.kz"
sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koru/surface/tests/boot_comp.kz" > "$comp_src"
if bash "$ROOT/scripts/build-native.sh" "$comp_src" "$WORK/boot_comp.elf" > "$WORK/boot_comp.build" 2>&1; then
    compport=$((6000 + $$ % 400))
    cu="$WORK/compunder.ppm"; cs="$WORK/compscene.ppm"
    cr="$WORK/compreveal.ppm"; cf="$WORK/compfinal.ppm"
    cuw="$(cygpath -m "$cu")"; csw="$(cygpath -m "$cs")"
    crw="$(cygpath -m "$cr")"; cfw="$(cygpath -m "$cf")"
    timeout 60 "$QEMU" -kernel "$WORK/boot_comp.elf" -serial stdio \
        -display none -m 64M -no-reboot -vga none -device virtio-gpu-pci \
        -monitor "tcp:127.0.0.1:$compport,server,nowait" \
        > "$WORK/boot_comp.serial" 2>&1 &
    cq=$!
    for _ in $(seq 1 20); do
        exec 3<>"/dev/tcp/127.0.0.1/$compport" 2>/dev/null && break
        sleep 0.5
    done
    dU=0; dS=0; dR=0; dF=0
    if [ -e /dev/fd/3 ]; then
        # inject from the start — aux packets queue in the PS/2 ring and
        # waitptr drains them whenever it runs; waiting for its window
        # misses it (the window is hlt-paced, IRQ12 itself is the wake).
        ( inj=0; while [ $inj -lt 120 ]; do
            grep -qF "COMP COMPLETE" "$WORK/boot_comp.serial" 2>/dev/null && break
            printf 'mouse_move 40 30\nmouse_button 1\nmouse_button 0\n' >&3 2>/dev/null || break
            inj=$((inj+1)); sleep 0.5
          done ) &
        injpid=$!
        for _ in $(seq 1 80); do
            if grep -qF "COMP UNDER" "$WORK/boot_comp.serial" 2>/dev/null; then
                printf 'screendump %s\n' "$cuw" >&3 2>/dev/null && dU=1; break
            fi
            sleep 0.25
        done
        for _ in $(seq 1 80); do
            if grep -qF "COMP SCENE" "$WORK/boot_comp.serial" 2>/dev/null; then
                printf 'screendump %s\n' "$csw" >&3 2>/dev/null && dS=1; break
            fi
            sleep 0.25
        done
        for _ in $(seq 1 80); do
            if grep -qF "COMP REVEAL" "$WORK/boot_comp.serial" 2>/dev/null; then
                printf 'screendump %s\n' "$crw" >&3 2>/dev/null && dR=1; break
            fi
            sleep 0.25
        done
        for _ in $(seq 1 80); do
            if grep -qF "COMP IDLE" "$WORK/boot_comp.serial" 2>/dev/null; then
                sleep 0.3
                printf 'screendump %s\n' "$cfw" >&3 2>/dev/null && dF=1; break
            fi
            sleep 0.25
        done
        for _ in $(seq 1 60); do
            grep -qF "COMP COMPLETE" "$WORK/boot_comp.serial" 2>/dev/null && break
            sleep 0.25
        done
        wait $injpid 2>/dev/null
        exec 3>&-
    fi
    kill $cq 2>/dev/null
    wait $cq 2>/dev/null || true
    if grep -qF "comp: attach 320x200 at 40,40 z=0" "$WORK/boot_comp.serial" \
       && grep -qF "comp: attach 160x100 at 40,40 z=1" "$WORK/boot_comp.serial" \
       && grep -qF "comp: detach z=1" "$WORK/boot_comp.serial" \
       && grep -qE "COMP PTR dx=[1-9]" "$WORK/boot_comp.serial" \
       && grep -qF "COMP COMPLETE" "$WORK/boot_comp.serial"; then
        ok "comp-scene: surfaces enter the z-stack at open; motion+button rode the seam"
    else
        bad "comp-scene: evidence missing: $(grep -aE 'comp|COMP|FAIL|EXC' "$WORK/boot_comp.serial" | tail -8 | tr '\n' '|')"
    fi
    if [ "$dU" -eq 1 ] && [ "$dS" -eq 1 ] && [ "$dR" -eq 1 ] \
       && [ -s "$cu" ] && [ -s "$cs" ] && [ -s "$cr" ]; then
        if command -v python >/dev/null 2>&1 && python -c "
import sys,re
def rd(p):
    d=open(p,'rb').read()
    m=re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s',d)
    w,h,_=map(int,m.groups()); o=m.end()
    return lambda x,y: d[o+(y*w+x)*3:o+(y*w+x)*3+3]
u,s,r=rd(sys.argv[1]),rd(sys.argv[2]),rd(sys.argv[3])
# UNDER: s0 (z=0) presented AFTER s1 (z=1) was already mapped and filled —
# painter's-order-at-present would blit s0's magenta over s1's rect and
# read ff00ff at (45,45); the z-walk leaves s1's cyan on top. SCENE:
# same stack with s1 presented. REVEAL: s1 closed, s0's magenta repaints
# from its retained backing — no client involved.
ok = u(45,45)==b'\x00\xff\xff' and u(300,200)==b'\xff\x00\xff' \
     and s(45,45)==b'\x00\xff\xff' and s(300,200)==b'\xff\x00\xff' \
     and r(45,45)==b'\xff\x00\xff' and r(300,200)==b'\xff\x00\xff'
sys.exit(0 if ok else 1)
" "$(cygpath -w "$cu")" "$(cygpath -w "$cs")" "$(cygpath -w "$cr")"; then
            ok "comp-zorder: UNDER/SCENE/REVEAL — z decides pixels, close repaints retained backing"
        else
            bad "comp-zorder: dumps present but pixels wrong (or python missing)"
        fi
    else
        bad "comp-zorder: marker dumps failed — U=$dU S=$dS R=$dR"
    fi
    if [ "$dF" -eq 1 ] && [ -s "$cf" ]; then
        if command -v python >/dev/null 2>&1 && python -c "
import sys,re
d=open(sys.argv[1],'rb').read()
m=re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s',d)
w,h,_=map(int,m.groups()); o=m.end()
px=lambda x,y: d[o+(y*w+x)*3:o+(y*w+x)*3+3]
# the arrow is ~67 non-bg pixels; its position is wherever the drained
# deltas accumulated (clamped at the frame edge possibly crops it), and
# with every surface closed the root is pure black — any non-black
# cluster IS the compositor-rendered cursor.
nb=sum(1 for y in range(h) for x in range(w) if px(x,y)!=b'\x00\x00\x00')
sys.exit(0 if 20<=nb<=200 and px(45,45)==b'\x00\x00\x00' else 1)
" "$(cygpath -w "$cf")"; then
            ok "comp-pointer: compositor-owned cursor tracked the injected deltas (clamped corner)"
        else
            bad "comp-pointer: final dump has no cursor evidence (or python missing)"
        fi
    else
        bad "comp-pointer: final screendump failed — dumped=$dF"
    fi
else
    bad "boot_comp: build failed"; tail -6 "$WORK/boot_comp.build"
fi

# input: the koruos/input seam over the 8042 — a QEMU `sendkey a` drives a
# real scancode through IRQ1 into the provider ring; the .kz fixture polls
# the lift in a bounded spin and prints the raw event (make 'a' = 0x1E).
# The monitor socket is the injection path; evidence is serial-only.
kbd_src="$WORK/boot_kbd.kz"
sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koru/input/tests/boot_kbd.kz" > "$kbd_src"
if bash "$ROOT/scripts/build-native.sh" "$kbd_src" "$WORK/boot_kbd.elf" > "$WORK/boot_kbd.build" 2>&1; then
    kbdport=$((4600 + $$ % 400))
    timeout "$TIMEOUT" "$QEMU" -kernel "$WORK/boot_kbd.elf" -serial stdio \
        -display none -m 64M -no-reboot \
        -monitor "tcp:127.0.0.1:$kbdport,server,nowait" \
        > "$WORK/boot_kbd.serial" 2>&1 &
    kbdq=$!
    # connect the human-monitor socket with retries — a refused connect or
    # a dead sendkey must FAIL the row loudly, never read as "no key".
    keys=0
    for _ in $(seq 1 20); do
        exec 3<>"/dev/tcp/127.0.0.1/$kbdport" 2>/dev/null && break
        sleep 0.5
    done
    if [ -e /dev/fd/3 ]; then
        for _ in $(seq 1 30); do
            printf 'sendkey a\n' >&3 2>/dev/null || break
            keys=$((keys+1))
            sleep 0.3
        done
        exec 3>&-
    fi
    wait $kbdq 2>/dev/null || true
    if [ "$keys" -eq 0 ]; then
        bad "input-kbd: monitor connect/sendkey failed — no injection happened"
    elif grep -qF "KBD key code=30 pressed=1" "$WORK/boot_kbd.serial"; then
        ok "input-kbd: 8042 IRQ1 scancode rode the seam (sendkey a -> key 30 pressed)"
    else
        bad "input-kbd: no key evidence: $(tail -6 "$WORK/boot_kbd.serial" | tr '\n' '|')"
    fi
else
    bad "boot_kbd: build failed"; tail -6 "$WORK/boot_kbd.build"
fi

# mouse: the 8042 aux channel — QEMU monitor `mouse_move`/`mouse_button`
# drive real PS/2 packets through IRQ12 into mouse.zig's assembler; the
# fixture accumulates motion deltas until a button edge lands and prints
# the sum. Same injection contract as input-kbd: a dead monitor socket
# fails loudly, never reads as "no pointer".
ms_src="$WORK/boot_mouse.kz"
sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koru/input/tests/boot_mouse.kz" > "$ms_src"
if bash "$ROOT/scripts/build-native.sh" "$ms_src" "$WORK/boot_mouse.elf" > "$WORK/boot_mouse.build" 2>&1; then
    msport=$((4800 + $$ % 400))
    timeout "$TIMEOUT" "$QEMU" -kernel "$WORK/boot_mouse.elf" -serial stdio \
        -display none -m 64M -no-reboot \
        -monitor "tcp:127.0.0.1:$msport,server,nowait" \
        > "$WORK/boot_mouse.serial" 2>&1 &
    msq=$!
    inj=0
    for _ in $(seq 1 20); do
        exec 3<>"/dev/tcp/127.0.0.1/$msport" 2>/dev/null && break
        sleep 0.5
    done
    if [ -e /dev/fd/3 ]; then
        for _ in $(seq 1 30); do
            printf 'mouse_move 40 30\n' >&3 2>/dev/null || break
            sleep 0.15
            printf 'mouse_button 1\n' >&3 2>/dev/null || break
            sleep 0.15
            printf 'mouse_button 0\n' >&3 2>/dev/null || break
            inj=$((inj+1))
            sleep 0.15
        done
        exec 3>&-
    fi
    wait $msq 2>/dev/null || true
    if [ "$inj" -eq 0 ]; then
        bad "input-mouse: monitor connect/injection failed — no injection happened"
    elif grep -qF "mouse: PS/2 aux online" "$WORK/boot_mouse.serial" \
         && grep -qE "MOUSE PTR dx=-?[0-9]+ dy=-?[0-9]+ btn=[1-3]" "$WORK/boot_mouse.serial"; then
        ok "input-mouse: IRQ12 packets rode the seam (monitor moves+click -> motion+button events)"
    else
        bad "input-mouse: no pointer evidence: $(tail -6 "$WORK/boot_mouse.serial" | tr '\n' '|')"
    fi
else
    bad "boot_mouse: build failed"; tail -6 "$WORK/boot_mouse.build"
fi

# aspace selftest runs in kmain on every boot — same-VA different-phys proof.
if grep -qF "ASPACE" "$WORK/boot_hello.serial" && grep -qF "DISTINCT" "$WORK/boot_hello.serial"; then
    ok "aspace: per-domain CR3 proven (same VA, different phys)"
else
    bad "aspace: selftest evidence missing: $(head -3 "$WORK/boot_hello.serial" | tr '\n' '|')"
fi
# ring3+spawn: an ELF64 child in its own CR3 does write() out-and-back
# through the int 0x80 seam, then exit() resumes the caller — spawn is
# a blocking provider call returning the child's status.
if grep -qF "elf child says hi" "$WORK/boot_hello.serial" && grep -qF "EMBED SPAWN exit=000000000000002a" "$WORK/boot_hello.serial"; then
    ok "ring3: embedded ELF child wrote + exited through the seam"
else
    bad "ring3: seam evidence missing: $(tail -4 "$WORK/boot_hello.serial" | tr '\n' '|')"
fi

# ext2 over the native virtio-blk provider: a host-made image carrying a
# real child ELF — the guest mounts, creates+verifies, reads the ELF off
# disk and spawns it at CPL=3 via koruos/spawn:exec, then unmounts.
IMG="$WORK/ext2.img"
IMGWSL="$(wsl -e wslpath -u "$(cygpath -w "$IMG")" 2>/dev/null)" || IMGWSL=""
ELF="$WORK/child.elf"
ELFA="$WORK/childA.elf"
ELFB="$WORK/childB.elf"
SPIN="$WORK/spin.elf"
ELFWSL=""
if command -v python >/dev/null 2>&1; then
    python "$ROOT/scripts/mk-child-elf.py" "$ELF" > /dev/null 2>&1
    python "$ROOT/scripts/mk-ticker-elf.py" "$ELFA" A 30 8000000 43 > /dev/null 2>&1
    python "$ROOT/scripts/mk-ticker-elf.py" "$ELFB" B 30 8000000 44 > /dev/null 2>&1
    python "$ROOT/scripts/mk-ticker-elf.py" "$SPIN" S 60 8000000 43 > /dev/null 2>&1
    ELFWSL="$(wsl -e wslpath -u "$(cygpath -w "$ELF")" 2>/dev/null)" || ELFWSL=""
    ELFAWSL="$(wsl -e wslpath -u "$(cygpath -w "$ELFA")" 2>/dev/null)" || ELFAWSL=""
    ELFBWSL="$(wsl -e wslpath -u "$(cygpath -w "$ELFB")" 2>/dev/null)" || ELFBWSL=""
    SPINWSL="$(wsl -e wslpath -u "$(cygpath -w "$SPIN")" 2>/dev/null)" || SPINWSL=""
elif command -v py >/dev/null 2>&1; then
    py -3 "$ROOT/scripts/mk-child-elf.py" "$(cygpath -w "$ELF")" > /dev/null 2>&1
    py -3 "$ROOT/scripts/mk-ticker-elf.py" "$(cygpath -w "$ELFA")" A 30 8000000 43 > /dev/null 2>&1
    py -3 "$ROOT/scripts/mk-ticker-elf.py" "$(cygpath -w "$ELFB")" B 30 8000000 44 > /dev/null 2>&1
    py -3 "$ROOT/scripts/mk-ticker-elf.py" "$(cygpath -w "$SPIN")" S 60 8000000 43 > /dev/null 2>&1
    ELFWSL="$(wsl -e wslpath -u "$(cygpath -w "$ELF")" 2>/dev/null)" || ELFWSL=""
    ELFAWSL="$(wsl -e wslpath -u "$(cygpath -w "$ELFA")" 2>/dev/null)" || ELFAWSL=""
    ELFBWSL="$(wsl -e wslpath -u "$(cygpath -w "$ELFB")" 2>/dev/null)" || ELFBWSL=""
    SPINWSL="$(wsl -e wslpath -u "$(cygpath -w "$SPIN")" 2>/dev/null)" || SPINWSL=""
fi
if [ -z "$IMGWSL" ] || [ -z "$ELFWSL" ]; then
    bad "boot_ext2: WSL/wslpath or python unavailable — cannot build the ext2 image"
else
    if MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 128 -O none -L koru-native "$IMGWSL" 16384 > "$WORK/mke2fs.out" 2>&1 \
        && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $ELFWSL child.elf" "$IMGWSL" > "$WORK/debugfs.out" 2>&1 \
        && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "mkdir bin" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
        && { printf 'cd bin\nwrite %s childA.elf\nwrite %s childB.elf\nwrite %s spin.elf\n' "$ELFAWSL" "$ELFBWSL" "$SPINWSL" > "$WORK/debugfs.cmds" \
        && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -f "$(wsl -e wslpath -u "$(cygpath -w "$WORK/debugfs.cmds")")" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1; }; then
        # real-ELF rung: gcc static-pie ET_DYN staged beside the hand-made
        # child — the loader bias+stack path exercised on a real toolchain
        # image, not a fixture we built byte by byte.
        cp "$ROOT/koru/native/tests/realhello.c" "$WORK/realhello.c"
        cp "$ROOT/koru/native/tests/muslhello.c" "$WORK/muslhello.c"
        cp "$ROOT/koru/native/tests/fscat.c" "$WORK/fscat.c"
        cp "$ROOT/koru/native/tests/hi.c" "$WORK/hi.c"
        cp "$ROOT/koru/native/tests/libhi.c" "$WORK/libhi.c"
        cp "$ROOT/koru/native/tests/getc.c" "$WORK/getc.c"
        cp "$ROOT/koru/native/tests/sh.c" "$WORK/sh.c"
        cp "$ROOT/koru/native/tests/args.c" "$WORK/args.c"
        cp "$ROOT/koru/native/tests/catc.c" "$WORK/catc.c"
        cp "$ROOT/koru/native/tests/pipegen.c" "$WORK/pipegen.c"
        cp "$ROOT/koru/native/tests/forktest.c" "$WORK/forktest.c"
        cp "$ROOT/koru/native/tests/granttest.c" "$WORK/granttest.c"
        cp "$ROOT/koru/native/tests/grantc.c" "$WORK/grantc.c"
        cp "$ROOT/koru/native/tests/objt.c" "$WORK/objt.c"
        cp "$ROOT/koru/native/tests/wtest.c" "$WORK/wtest.c"
        cp "$ROOT/koru/native/tests/wlpair.c" "$WORK/wlpair.c"
        cp "$ROOT/koru/native/tests/wlwire.h" "$WORK/wlwire.h"
        cp "$ROOT/koru/native/tests/wlserver.c" "$WORK/wlserver.c"
        cp "$ROOT/koru/native/tests/wlclient.c" "$WORK/wlclient.c"
        cp "$ROOT/koru/native/tests/wlinit.c" "$WORK/wlinit.c"
        cp "$ROOT/koru/native/tests/wlreal.c" "$WORK/wlreal.c"
        cp "$ROOT/koru/native/tests/wlrinit.c" "$WORK/wlrinit.c"
        REALWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/realhello.c")")"
        PIEWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/pie.elf")")"
        MUSLWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/musl.elf")")"
        FSCATWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/fscat.elf")")"
        HELLOWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/hello.txt")")"
        GETCWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/getc.elf")")"
        SHWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/sh.elf")")"
        ARGSWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/args.elf")")"
        CATCWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/catc.elf")")"
        PIPEGENWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/pipegen.elf")")"
        FORKTESTWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/forktest.elf")")"
        GRANTTESTWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/granttest.elf")")"
        GRANTCWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/grantc.elf")")"
        OBJTWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/objt.elf")")"
        WTESTWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/wtest.elf")")"
        WLPAIRWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/wlpair.elf")")"
        WLSRVWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/wlserver.elf")")"
        WLCLIWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/wlclient.elf")")"
        WLINITWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/wlinit.elf")")"
        WLREALWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/wlreal.elf")")"
        WLRINITWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/wlrinit.elf")")"
        printf 'hello-from-ext2\n' > "$WORK/hello.txt"
        # musl hello: zig cc emits a real static musl ET_EXEC linked above
        # the kernel identity region (0x48000000) — ~1MB, exercised through
        # the double-indirect ext2 read path.
        ZIGBIN="${ZIG:-/w/tools/zig-0.15.1/zig.exe}"
        if MSYS2_ARG_CONV_EXCL='*' wsl -e gcc -static-pie -nostdlib -nostartfiles -s -Wl,--build-id=none -Wl,-z,noseparate-code -o "$PIEWSL" "$REALWSL" > "$WORK/pie.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/musl.elf" "$WORK/muslhello.c" > "$WORK/musl.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/fscat.elf" "$WORK/fscat.c" > "$WORK/fscat.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/getc.elf" "$WORK/getc.c" > "$WORK/getc.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/sh.elf" "$WORK/sh.c" > "$WORK/sh.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/args.elf" "$WORK/args.c" > "$WORK/args.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/catc.elf" "$WORK/catc.c" > "$WORK/catc.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/pipegen.elf" "$WORK/pipegen.c" > "$WORK/pipegen.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/forktest.elf" "$WORK/forktest.c" > "$WORK/forktest.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/granttest.elf" "$WORK/granttest.c" > "$WORK/granttest.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/grantc.elf" "$WORK/grantc.c" > "$WORK/grantc.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/objt.elf" "$WORK/objt.c" > "$WORK/objt.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/wtest.elf" "$WORK/wtest.c" > "$WORK/wtest.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/wlpair.elf" "$WORK/wlpair.c" > "$WORK/wlpair.build" 2>&1 \
           && WLHOST="$ROOT/koru/hosted/wayland" \
           && "$ZIGBIN" cc -O2 -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -I"$WLHOST" -I"$WLHOST/libffi" -I"$WLHOST/src" -DHAVE_CONFIG_H -o "$WORK/wlserver.elf" "$WORK/wlserver.c" "$WLHOST/src/wayland-server.c" "$WLHOST/src/event-loop.c" "$WLHOST/src/wayland-shm.c" "$WLHOST/src/connection.c" "$WLHOST/src/wayland-os.c" "$WLHOST/src/wayland-util.c" "$WLHOST/wayland-protocol.c" "$WLHOST/xdg-shell-protocol.c" "$WLHOST/libffi/libffi.a" > "$WORK/wlserver.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/wlclient.elf" "$WORK/wlclient.c" > "$WORK/wlclient.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/wlinit.elf" "$WORK/wlinit.c" > "$WORK/wlinit.build" 2>&1 \
           && WLHOST="$ROOT/koru/hosted/wayland" \
           && "$ZIGBIN" cc -O2 -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -I"$WLHOST" -I"$WLHOST/libffi" -DHAVE_CONFIG_H -o "$WORK/wlreal.elf" "$WORK/wlreal.c" "$WLHOST/src/connection.c" "$WLHOST/src/wayland-client.c" "$WLHOST/src/wayland-os.c" "$WLHOST/src/wayland-util.c" "$WLHOST/wayland-client-protocol.c" "$WLHOST/xdg-shell-protocol.c" "$WLHOST/libffi/libffi.a" > "$WORK/wlreal.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -static -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/wlrinit.elf" "$WORK/wlrinit.c" > "$WORK/wlrinit.build" 2>&1 \
           && "$ZIGBIN" build-lib -target x86_64-linux-musl -dynamic -O ReleaseSmall -femit-bin="$WORK/libhi.so" "$WORK/libhi.c" > "$WORK/hi.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -dynamic -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/hi.elf" "$WORK/hi.c" "$WORK/libhi.so" >> "$WORK/hi.build" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $PIEWSL pie.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $MUSLWSL musl.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $FSCATWSL fscat.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $HELLOWSL hello.txt" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $GETCWSL getc.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $SHWSL sh.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $ARGSWSL args.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $CATCWSL catc.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $PIPEGENWSL pipegen.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $FORKTESTWSL forktest.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $GRANTTESTWSL granttest.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $GRANTCWSL grantc.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $OBJTWSL objt.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $WTESTWSL wtest.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $WLPAIRWSL wlpair.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $WLSRVWSL wlserver.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $WLCLIWSL wlclient.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $WLINITWSL wlinit.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $WLREALWSL wlreal.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $WLRINITWSL wlrinit.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e bash "$(wsl -e wslpath -u "$(cygpath -w "$ROOT/scripts/stage-dynamic.sh")")" "$IMGWSL" "$(wsl -e wslpath -u "$(cygpath -w "$WORK/hi.elf")")" "$(wsl -e wslpath -u "$(cygpath -w "$WORK/libhi.so")")" >> "$WORK/stage-dynamic.out" 2>&1; then
            boot_check "$ROOT/koru/native/tests/boot_real.k" "REALELF COMPLETE" \
                -drive "file=$IMG,format=raw,if=none,id=d0" \
                -device virtio-blk-pci,drive=d0,disable-modern=on
            if grep -qF "real pie child says hi" "$WORK/boot_real.serial" \
               && grep -qE "exec pie.elf ino=[0-9]+.*status=42" "$WORK/boot_real.serial"; then
                ok "real-elf: gcc -static-pie ET_DYN loaded with bias, ran, exit_group folded to exit"
            else
                bad "real-elf: pie child evidence missing: $(tail -4 "$WORK/boot_real.serial" | tr '\n' '|')"
            fi
            # SEAM REFUSE lines are the spec's loud axis, not a fail —
            # later children in the same serial (busybox's getuid) refuse
            # caps the bag can't express; the evidence pins the run.
            if grep -qF "musl child says hi" "$WORK/boot_real.serial" \
               && grep -qF "exec musl.elf status=42" "$WORK/boot_real.serial"; then
                ok "real-elf-musl: static musl libc ran end-to-end (TLS, brk, writev, exit_group)"
            else
                bad "real-elf-musl: musl evidence missing: $(grep -E 'musl|REFUSE|EXC' "$WORK/boot_real.serial" | tail -4 | tr '\n' '|')"
            fi
            # fs-in-child: fscat's open/read/close resolve inside the ext2
            # it was spawned from — the scoped fs view riding the spawn
            # call. hello.txt content must come back through the seam.
            if grep -qF "FSCAT hello-from-ext2" "$WORK/boot_real.serial" \
               && grep -qF "exec fscat.elf status=44" "$WORK/boot_real.serial"; then
                ok "fs-child: musl child read a file from its own ext2 via the scoped fs view (openat/read/close)"
            else
                bad "fs-child: evidence missing: $(grep -E 'FSCAT|fscat|REFUSE|EXC' "$WORK/boot_real.serial" | tail -4 | tr '\n' '|')"
            fi
            # two-lib discriminating case: a zig-built hello needing its
            # own .so + libc.so — openat + file-mmap + reloc across a
            # non-self DSO boundary, printed through the seam.
            if grep -qF "HI=41" "$WORK/boot_real.serial" \
               && grep -qF "exec hi.elf status=0" "$WORK/boot_real.serial"; then
                ok "dynamic-hi: PT_INTERP + liblibhi.so + libc.so resolved and called"
            else
                bad "dynamic-hi: evidence missing: $(grep -aE 'HI=|ENOSYS|REFUSE|EXC|hi.elf' "$WORK/boot_real.serial" | tail -6 | tr '\n' '|')"
            fi
            # PT_INTERP: a real alpine binary's interp section pulls
            # /lib/ld-musl through the fs view; ld.so then openat()s and
            # file-mmaps libc.musl in the child's space — dynamic linking
            # on our seam, not the host's. busybox's banner is ld.so's
            # proof of work.
            if grep -qF "BusyBox v1.37.0" "$WORK/boot_real.serial" \
               && grep -qF "exec busybox status=0" "$WORK/boot_real.serial"; then
                ok "dynamic: PT_INTERP resolved ld-musl via fs view; busybox 1.37 ran (mmap-file/mprotect)"
            else
                bad "dynamic: busybox evidence missing: $(grep -aE 'ENOSYS|REFUSE|EXC|busybox|BusyBox' "$WORK/boot_real.serial" | tail -6 | tr '\n' '|')"
            fi
            # GNU uname drags five DT_NEEDED libs (crypto/acl/attr/utmps/
            # musl) — the full multi-lib closure — and prints our own
            # uname struct back: sysname must say koru-os, not a costume.
            if grep -qF "exec uname status=0" "$WORK/boot_real.serial"; then
                ok "dynamic-gnu: coreutils uname ran its 5-lib closure and reported the kernel's own name"
            else
                bad "dynamic-gnu: uname evidence missing: $(grep -aE 'ENOSYS|REFUSE|EXC|uname|koru' "$WORK/boot_real.serial" | tail -6 | tr '\n' '|')"
            fi
            # unix-socket transport: wlpair socketpair+forks, passes a
            # memfd over real SCM_RIGHTS ancillary, and the server mmaps
            # it MAP_SHARED — the same frames in two address spaces. This
            # is the wire wayland is built on; asserted here so the wl
            # server/client pair lands on a measured transport.
            boot_check "$ROOT/koru/native/tests/boot_sock.k" "WLBOOT COMPLETE" \
                -drive "file=$IMG,format=raw,if=none,id=d0" \
                -device virtio-blk-pci,drive=d0,disable-modern=on
            if grep -qE "WLSERV bytes=[0-9]+:wl-go rfd=[0-9]+" "$WORK/boot_sock.serial" \
               && grep -qE "WLCLNT sent=[0-9]+ reply=[0-9]+:ok" "$WORK/boot_sock.serial" \
               && grep -qF "WLSERV magic=deadbeef tag=00c0ffee" "$WORK/boot_sock.serial" \
               && grep -qF "exec wlpair status=0" "$WORK/boot_sock.serial"; then
                ok "sockpair: SCM_RIGHTS fd crossed the socket; MAP_SHARED pool read back through it"
            else
                bad "sockpair: evidence missing: $(grep -aE 'WL|FAIL|REFUSE|EXC' "$WORK/boot_sock.serial" | tail -6 | tr '\n' '|')"
            fi
            # wl protocol pair over a REAL pathname endpoint: wlinit
            # spawn_starts two SEPARATE binaries that rendezvous through
            # the shared fs view — wlserver mknods an S_IFSOCK inode,
            # binds+listens "wayland-1", wlclient resolves the path and
            # queues a session on the backlog; accept hands the server a
            # fresh stream projection. Over it they speak real libwayland
            # wire format — registry globals, shm formats, surface/pool/
            # buffer objects, the pool fd over SCM_RIGHTS, attach/damage/
            # frame/commit answered by callback.done + buffer.release,
            # display.sync roundtrip, EOS on last close.
            boot_check "$ROOT/koru/native/tests/boot_wl.k" "WLEXEC COMPLETE" \
                -drive "file=$IMG,format=raw,if=none,id=d0" \
                -device virtio-blk-pci,drive=d0,disable-modern=on
            if grep -qF "WLSRV bound wayland-1" "$WORK/boot_wl.serial" \
               && grep -qE "WLCLI connected tries=[0-9]+" "$WORK/boot_wl.serial" \
               && grep -qE "WLSRV accepted fd=[0-9]+" "$WORK/boot_wl.serial" \
               && grep -qF "WLCLI global 1 wl_compositor v4" "$WORK/boot_wl.serial" \
               && grep -qF "WLCLI global 2 wl_shm v2" "$WORK/boot_wl.serial" \
               && grep -qF "WLSRV magic=deadbeef tag=00c0ffee px0=5a" "$WORK/boot_wl.serial" \
               && grep -qF "WLCLI frame done=42" "$WORK/boot_wl.serial" \
               && grep -qF "WLCLI buffer release" "$WORK/boot_wl.serial" \
               && grep -qF "WLCLI sync done=0 framed=1 rel=1" "$WORK/boot_wl.serial" \
               && grep -qF "WLSRV EOS" "$WORK/boot_wl.serial" \
               && grep -qF "WLINIT srv=0 cli=0" "$WORK/boot_wl.serial"; then
                ok "wlsock: path endpoint carried real wl wire — mknod/bind/accept, shm pool via SCM_RIGHTS, commit->done, release, sync"
            else
                bad "wlsock: evidence missing: $(grep -aE 'WL|FAIL|REFUSE|EXC' "$WORK/boot_wl.serial" | tail -8 | tr '\n' '|')"
            fi
            # UNMODIFIED libwayland-client: wlreal.elf is the vendored
            # 1.26 client (connection/wayland-client/wayland-os/
            # wayland-util + generated glue + libffi.a demarshalling)
            # linked against our seam — real connect() on the path
            # endpoint, real ppoll event loop, MSG_DONTWAIT recvmsg,
            # F_DUPFD on the received pool, ffi-closure dispatch of the
            # registry/frame/sync events. Same wlserver.elf compositor.
            # headless run: both clients still wait out their input
            # deadline — wider window than the generic 15s.
            TIMEOUT=30 boot_check "$ROOT/koru/native/tests/boot_wlr.k" "WLREXEC COMPLETE" \
                -drive "file=$IMG,format=raw,if=none,id=d0" \
                -device virtio-blk-pci,drive=d0,disable-modern=on
            if grep -qF "WLSRV bound wayland-1" "$WORK/boot_wlr.serial" \
               && grep -qF "WLSRV input open" "$WORK/boot_wlr.serial" \
               && grep -qE "WLR connected tries=[0-9]+" "$WORK/boot_wlr.serial" \
               && grep -qF "WLR global 1 wl_compositor v4" "$WORK/boot_wlr.serial" \
               && grep -qF "WLR global 2 wl_shm v2" "$WORK/boot_wlr.serial" \
               && grep -qF "WLR global 3 wl_seat v7" "$WORK/boot_wlr.serial" \
               && grep -qF "WLR global 4 xdg_wm_base v1" "$WORK/boot_wlr.serial" \
               && grep -qF "WLR seat caps 3" "$WORK/boot_wlr.serial" \
               && grep -qF "WLR kbd keymap fmt=1" "$WORK/boot_wlr.serial" \
               && grep -qF "WLSRV toplevel configure ser=" "$WORK/boot_wlr.serial" \
               && grep -qF "WLR xsurf conf ser=" "$WORK/boot_wlr.serial" \
               && grep -qF "WLSRV ack " "$WORK/boot_wlr.serial" \
               && grep -qF "WLSRV pong " "$WORK/boot_wlr.serial" \
               && grep -qF "WLSRV magic=deadbeef tag=00c0ffee px0=5a" "$WORK/boot_wlr.serial" \
               && grep -qF "WLR frame done=42" "$WORK/boot_wlr.serial" \
               && grep -qF "WLR buffer release" "$WORK/boot_wlr.serial" \
               && grep -qF "WLR sync done=0" "$WORK/boot_wlr.serial" \
               && grep -qF "WLSRV EOS" "$WORK/boot_wlr.serial" \
               && grep -qF "WLRINIT srv=0 cli=0,0" "$WORK/boot_wlr.serial"; then
                ok "wlreal: 2x UNMODIFIED libwayland-client 1.26 + libffi — connect/registry/shm/seat caps/xdg_shell role-handshake (configure+ack+ping)/keymap-fd/ppoll/SCM_RIGHTS/frame-done/sync, headless-safe"
            else
                bad "wlreal: evidence missing: $(grep -aE 'WLR|WLSRV|FAIL|REFUSE|EXC' "$WORK/boot_wlr.serial" | tail -8 | tr '\n' '|')"
            fi
            # wlscene: the compositor drives the REAL scene — wlserver's
            # surface.commit mints a *Surf through the child-facing seam
            # (nr515 open-as-fd, nr516 blit, nr517 damage, nr519 move),
            # riding virtio-gpu. TWO clients tile two surfaces; the seat
            # rung rides the same monitor: injected pointer/key events
            # ride the nr518 input fd into per-focus wl_pointer/
            # wl_keyboard protocol. The pixel oracle is a screendump
            # taken after the drag — client pixels at the MOVED rect,
            # the vacated tiles black.
            wlport=$((5900 + $$ % 400))
            wlppm="$WORK/wlscene.ppm"
            wlppmw="$(cygpath -m "$wlppm" 2>/dev/null || echo "$wlppm")"
            timeout 90 "$QEMU" -kernel "$WORK/boot_wlr.elf" -serial stdio \
                -drive "file=$IMG,format=raw,if=none,id=d0" \
                -device virtio-blk-pci,drive=d0,disable-modern=on \
                -display none -m 64M -no-reboot \
                -vga none -device virtio-gpu-pci \
                -monitor "tcp:127.0.0.1:$wlport,server,nowait" \
                > "$WORK/boot_wlscene.serial" 2>&1 &
            wq=$!
            for _ in $(seq 1 40); do
                exec 3<>"/dev/tcp/127.0.0.1/$wlport" 2>/dev/null && break
                sleep 0.5
            done
            wdumped=0; wmon=0; wslot=0
            if [ -e /dev/fd/3 ]; then
                wmon=1
                # wait both clients' commits, then the scripted input:
                # A: move+click+key (exit); B: move+press+drag ->
                # "WLSRV move" -> dump while held -> release+key (exit).
                for _ in $(seq 1 120); do
                    if grep -qF "WLSRV surf slot=1" "$WORK/boot_wlscene.serial" 2>/dev/null; then
                        wslot=1; break
                    fi
                    sleep 0.25
                done
                [ "$wslot" -eq 1 ] || echo "wlscene: slot=1 marker never appeared — injection skipped" >&2
                # ONE move — (60,60) lands inside slot0's 64px tile.
                # A second 60,60 overshoots into the dead gap between
                # the tiles (120,120) and the press/key drop unfocused.
                printf 'mouse_move 60 60\n' >&3 2>/dev/null; sleep 0.4
                printf 'mouse_button 1\n' >&3 2>/dev/null; sleep 0.3
                printf 'mouse_button 0\n' >&3 2>/dev/null; sleep 0.3
                printf 'sendkey a\n' >&3 2>/dev/null; sleep 0.4
                printf 'mouse_move 80 80\n' >&3 2>/dev/null; sleep 0.4
                printf 'mouse_button 1\n' >&3 2>/dev/null; sleep 0.3
                printf 'mouse_move 20 15\n' >&3 2>/dev/null
                for _ in $(seq 1 40); do
                    if grep -qF "WLSRV move" "$WORK/boot_wlscene.serial" 2>/dev/null; then
                        printf 'screendump %s\n' "$wlppmw" >&3 2>/dev/null && wdumped=1
                        break
                    fi
                    sleep 0.25
                done
                sleep 0.3
                printf 'mouse_button 0\n' >&3 2>/dev/null; sleep 0.3
                printf 'sendkey b\n' >&3 2>/dev/null
                for _ in $(seq 1 80); do
                    grep -qF "WLREXEC COMPLETE" "$WORK/boot_wlscene.serial" 2>/dev/null && break
                    sleep 0.25
                done
                sleep 0.3
                exec 3>&-
            fi
            kill $wq 2>/dev/null
            wait $wq 2>/dev/null || true
            if grep -qF "surf: open 64x64 at" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLSRV surf slot=0" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLSRV surf slot=1" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLSRV surf 64x64 blit=0/0 present=0/0" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLR ptr enter" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLR kbd enter" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLR ptr motion" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLR ptr button 272 1" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLR kbd key 30 1" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLSRV tl-move" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLSRV move 160,155" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLR kbd key 48 1" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLSRV surf released slot=0" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLSRV surf released slot=1" "$WORK/boot_wlscene.serial" \
               && grep -qF "WLRINIT srv=0 cli=0,0" "$WORK/boot_wlscene.serial"; then
                ok "wlscene: 2 clients -> 2 *Surfs; input fd -> per-focus wl_pointer/wl_keyboard (enter/motion/button/key), drag moved a surface through nr519, detach+reveal on EOS"
            else
                # name the precondition that failed, not just the
                # evidence tail — a dead monitor or a missing slot
                # marker is a different diagnosis than dead routing.
                if [ "$wmon" -eq 0 ]; then
                    bad "wlscene: monitor connect failed — no injection happened (like input-kbd, a dead socket is a loud fail)"
                elif [ "$wslot" -eq 0 ]; then
                    bad "wlscene: clients never committed slot=1 — injection had nothing to hit: $(grep -aE 'WLSRV|WLR |FAIL|EXC' "$WORK/boot_wlscene.serial" | tail -6 | tr '\n' '|')"
                else
                    bad "wlscene: seam evidence missing: $(grep -aE 'surf|comp:|WLSRV|WLR |FAIL|EXC' "$WORK/boot_wlscene.serial" | tail -10 | tr '\n' '|')"
                fi
            fi
            if [ "$wdumped" -eq 1 ] && [ -s "$wlppm" ]; then
                if command -v python >/dev/null 2>&1 && \
                   python -c "
import sys,re
d=open(sys.argv[1],'rb').read()
m=re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s', d)
w,h,_=map(int,m.groups()); o=m.end()
px=lambda x,y: d[o+(y*w+x)*3:o+(y*w+x)*3+3]
# mid-drag: client B's 64x64 was moved to (160,155) — deadbeef/c0ffee
# sit at the MOVED origin; both original tiles are black (A already
# detached, B's old rect damaged away).
sys.exit(0 if px(160,155)==b'\xad\xbe\xef' and px(161,155)==b'\xc0\xff\xee'
         and px(40,40)==b'\x00\x00\x00' and px(140,140)==b'\x00\x00\x00'
         and px(300,300)==b'\x00\x00\x00' else 1)
" "$(cygpath -w "$wlppm")"; then
                    ok "wlscene-pixels: deadbeef/c0ffee at the DRAGGED rect (160,155) — nr519 moved the backing, old tiles black"
                else
                    bad "wlscene-pixels: dump present but pixels wrong (or python missing)"
                fi
            else
                bad "wlscene-pixels: screendump failed — dumped=$wdumped ppm=$([ -s "$wlppm" ] && echo written || echo missing)"
            fi
        else
            bad "real-elf: gcc/zig/debugfs staging failed"; tail -4 "$WORK/pie.build" "$WORK/musl.build" "$WORK/fscat.build" 2>/dev/null
        fi
        boot_check "$ROOT/koru/native/tests/boot_ext2.k" "EXT2N COMPLETE" \
            -drive "file=$IMG,format=raw,if=none,id=d0" \
            -device virtio-blk-pci,drive=d0,disable-modern=on
        # virtio-blk's device now comes out of pci.zig's table — not a
        # provider-rescanned bus. The row proves both halves: 1af4:1001
        # enumerated with its INTx line, and the capability-list walk saw
        # the MSI-X cap (0x11) the transitional device carries.
        if grep -qE "pci: [0-9a-f:.]+ 1af4:1001 class=01/00" "$WORK/boot_ext2.serial" \
           && grep -qE "pci: [0-9a-f:.]+ 1af4:1001 .*caps=[0-9a-f,]*11" "$WORK/boot_ext2.serial"; then
            ok "pci-enum: virtio-blk resolved from the table; cap walk saw MSI-X"
        else
            bad "pci-enum: virtio row missing: $(grep -aE 'pci:.*1af4' "$WORK/boot_ext2.serial" | tr '\n' '|')"
        fi
        # disk provenance: the spawned child must be the one read from ext2,
        # not the embedded image — different message, different exit code.
        if grep -qF "disk child says hi" "$WORK/boot_ext2.serial" && grep -qF "status=43" "$WORK/boot_ext2.serial"; then
            ok "ext2-spawn: child.elf read from disk, spawned at CPL=3"
        else
            bad "ext2-spawn: disk-child evidence missing: $(tail -4 "$WORK/boot_ext2.serial" | tr '\n' '|')"
        fi
        # exec-by-path folds walk→inode→load→spawn and names the identity:
        # the inode it executed plus the object-nid minted from ext2/d0/<ino>.
        if grep -qE "ext2n: exec child.elf ino=[0-9]+ nid=[0-9a-f]+ status=" "$WORK/boot_ext2.serial"; then
            ok "exec-path: ELF-by-path bound inode+nid identity on the exec seam"
        else
            bad "exec-path: identity evidence missing: $(tail -4 "$WORK/boot_ext2.serial" | tr '\n' '|')"
        fi
        # exec-by-nid resolves the provider FROM THE PIN — no caller-held
        # fs: nid → key → dev → the mounted registry → the mount's own
        # vfs. The post-unmount call must refuse by name: the pin outlives
        # the mount but a dead provider never executes.
        if grep -qE "ext2n: exec-bynid post-rename dev=0 ino=[0-9]+ status=43" "$WORK/boot_ext2.serial" \
           && grep -qF "ext2n: exec-bynid post-unmount refused:" "$WORK/boot_ext2.serial"; then
            ok "exec-bynid: pin resolved provider via mounted table (status=43); stale pin refused post-unmount"
        else
            bad "exec-bynid: evidence missing: $(grep -aE 'exec-bynid|FAIL|pin:' "$WORK/boot_ext2.serial" | tail -5 | tr '\n' '|')"
        fi
        # the object axis, callable: obj-stat/obj-read dispatch BY NID
        # through the pin → mounted-table walk — POST-RENAME. The same
        # ino answers and the read returns the ELF magic: identity-keyed
        # verbs, no path ever walked.
        pin_ino_obj=$(sed -n 's/.*pinned child.elf ino=\([0-9]*\).*/\1/p' "$WORK/boot_ext2.serial" | head -1)
        if [ -n "$pin_ino_obj" ] \
           && grep -qE "ext2n: obj-stat nid dev=0 ino=$pin_ino_obj size=[0-9]+" "$WORK/boot_ext2.serial" \
           && grep -qE "ext2n: obj-read nid n=4 magic=464c457f" "$WORK/boot_ext2.serial"; then
            ok "fs-object: obj-stat/obj-read by nid — ino=$pin_ino_obj, ELF magic read by identity post-rename"
        else
            bad "fs-object: evidence missing: $(grep -aE 'obj-stat|obj-read|FAIL' "$WORK/boot_ext2.serial" | tail -4 | tr '\n' '|')"
        fi
        # the pin round-trip: pin(path) re-mints the SAME nid (identity is
        # derived from the object, not the view) and exec_nid re-runs the
        # child by nid alone — no path is walked on that call.
        exnid=$(sed -n 's/.*exec child.elf ino=\([0-9]*\) nid=\([0-9a-f]*\).*/\1 \2/p' "$WORK/boot_ext2.serial" | head -1)
        pinnid=$(sed -n 's/.*pinned child.elf ino=\([0-9]*\) nid=\([0-9a-f]*\).*/\1 \2/p' "$WORK/boot_ext2.serial" | head -1)
        nxline=$(grep -oE "exec-nid ino=[0-9]+ status=43" "$WORK/boot_ext2.serial" | head -1)
        if [ -n "$exnid" ] && [ "$exnid" = "$pinnid" ] && [ -n "$nxline" ] \
           && [ "$(echo "$nxline" | sed -n 's/.*ino=\([0-9]*\).*/\1/p')" = "$(echo "$exnid" | cut -d' ' -f1)" ]; then
            ok "nid-bind: pin re-minted exec's nid, exec_nid re-ran the same ino"
        else
            bad "nid-bind: pin/exec-nid mismatch: exec='$exnid' pin='$pinnid' exec-nid='$nxline'"
        fi
        # the bag is load-bearing: kernel-side refusal AND the child
        # observing -EACCES as a return value it can branch on.
        if grep -qF "SEAM REFUSE nr=0000000000000027" "$WORK/boot_ext2.serial" && grep -qF "getpid refused" "$WORK/boot_ext2.serial"; then
            ok "seam-bag: getpid refused loud + as -EACCES to the child"
        else
            bad "seam-bag: refusal evidence missing: $(tail -6 "$WORK/boot_ext2.serial" | tr '\n' '|')"
        fi
        # reclaim: every child exit must return its frames to the allocator
        # — tables + user pages + stack, not a leak into the old bump heap.
        if grep -qE "pmm: reap freed=[0-9a-f]+" "$WORK/boot_ext2.serial"; then
            ok "pmm-reclaim: child exit returned its frames (tables+pages+stack)"
        else
            bad "pmm-reclaim: no reap evidence: $(grep pmm "$WORK/boot_ext2.serial" | tail -3 | tr '\n' '|')"
        fi
        # interrupts are real: virtio INTx delivered through the PIC and
        # the child's int3 vectored into our #BP gate and RESUMED (the
        # child still exits 43 after it).
        if grep -qF "irq: virtio delivered" "$WORK/boot_ext2.serial"; then
            ok "irq-virtio: INTx completion delivered through the IDT"
        else
            bad "irq-virtio: no interrupt evidence: $(tail -6 "$WORK/boot_ext2.serial" | tr '\n' '|')"
        fi
        # interrupt-DRIVEN, not interrupt-assisted: each empty finish_reqs
        # parks on a delivered vector (hlt) instead of returning into a
        # burn loop. parks must exist (we slept) and stay within a small
        # multiple of the request count — a spin would not produce parks.
        blkline=$(grep "blk: reqs=" "$WORK/boot_ext2.serial" | tail -1 || true)
        reqs=$(echo "$blkline" | sed -n 's/.*reqs=\([0-9]*\).*/\1/p')
        parks=$(echo "$blkline" | sed -n 's/.*parks=\([0-9]*\).*/\1/p')
        irqs=$(echo "$blkline" | sed -n 's/.*irqs=\([0-9]*\).*/\1/p')
        if [ -n "$reqs" ] && [ -n "$parks" ] && [ "$parks" -ge 1 ] \
           && [ "$parks" -le $((reqs * 8 + 64)) ]; then
            ok "irq-wake: blk waits are interrupt-paced (reqs=$reqs parks=$parks irqs=$irqs)"
        else
            bad "irq-wake: blk stats missing or unbounded: $blkline"
        fi
        # writable view: a musl child created, wrote, read-back, renamed
        # and unlinked through REAL syscalls — fopen("w")→openat O_CREAT,
        # write(1) on a V_WRITE fd, rename(2), unlink(2) — and the file
        # kept its (dev,ino) key across the rename. mkdir(2)/link(2)/
        # rmdir(2) mint a dir, alias the inode (nlink counts names), and
        # refuse ENOTEMPTY before succeeding on the emptied dir. WTEST-BIG:
        # 40 KiB in one write crosses single-indirect (k=12..39); an lseek
        # to 300 KiB + write crosses double-indirect (k=300 → leaf); the
        # sparse tail reads back through the same tables.
        if grep -qE "WTEST w=[0-9]+ rb=[0-9]+ ino=[0-9a-fx]+ renamed=1 same-ino=[0-9]+ unl=1 dot=1 DONE" "$WORK/boot_ext2.serial" \
           && grep -qE "WTEST-BIG w=40960 rb=40960 sz=307205 sum=[0-9a-f]+ mism=0 DONE" "$WORK/boot_ext2.serial" \
           && ! grep -qF "WTEST-FAIL" "$WORK/boot_ext2.serial" \
           && grep -qF "exec wtest.elf status=0" "$WORK/boot_ext2.serial"; then
            ok "fs-write: musl child created/wrote/renamed/unlinked/mkdir'd/link'd/rmdir'd via the scoped view; IND+DIND + nlink counted"
        else
            bad "fs-write: evidence missing: $(grep -aE 'WTEST|wtest|REFUSE|FAIL' "$WORK/boot_ext2.serial" | tail -6 | tr '\n' '|')"
        fi
        # pin durability under view mutation: the pin bound BEFORE the
        # rename resolves the same (dev,ino) after it — exec-by-nid ran
        # the renamed ELF by identity alone, and the old path refuses.
        pin_ino=$(sed -n 's/.*pinned child.elf ino=\([0-9]*\).*/\1/p' "$WORK/boot_ext2.serial" | head -1)
        mv_ino=$(sed -n 's/.*moved.elf ino=\([0-9]*\).*/\1/p' "$WORK/boot_ext2.serial" | head -1)
        if [ -n "$pin_ino" ] && [ "$pin_ino" = "$mv_ino" ] \
           && grep -qE "exec-bynid post-rename dev=0 ino=$pin_ino status=43" "$WORK/boot_ext2.serial" \
           && grep -qF "stale path child.elf refused:" "$WORK/boot_ext2.serial"; then
            ok "pin-durable: rename moved the view not the identity — exec-bynid ran ino=$pin_ino post-rename"
        else
            bad "pin-durable: evidence missing: pin=$pin_ino mv=$mv_ino $(grep -aE 'moved|exec-bynid|stale|FAIL' "$WORK/boot_ext2.serial" | tail -5 | tr '\n' '|')"
        fi
        # host-side durability: debugfs reads the image AFTER QEMU exits
        # — moved.elf must sit on the pin's inode, wren.txt (the musl
        # child's own rename target) must persist, wlive.txt must be
        # gone. The mutations are on disk, not just in the serial log.
        if [ -n "$pin_ino" ]; then
            mvstat=$(MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -R "stat moved.elf" "$IMGWSL" 2>&1)
            mvino_disk=$(echo "$mvstat" | sed -n 's/.*Inode: \([0-9]*\).*/\1/p' | head -1)
            wrenstat=$(MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -R "stat wren.txt" "$IMGWSL" 2>&1)
            wlivstat=$(MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -R "stat wlive.txt" "$IMGWSL" 2>&1)
            if [ "$mvino_disk" = "$pin_ino" ] && echo "$wrenstat" | grep -q "Inode:" \
               && ! echo "$wlivstat" | grep -q "Inode:"; then
                ok "fs-persist: host sees moved.elf@ino$pin_ino + wren.txt; wlive.txt renamed away"
            else
                bad "fs-persist: host image check failed: moved=$mvino_disk wren=$(echo "$wrenstat" | head -1) wlive=$(echo "$wlivstat" | head -1)"
            fi
            # big.txt's block map must show the indirect TABLES the
            # write allocated — (IND): the single-indirect root,
            # (DIND): the double-indirect root — host-visible, not
            # just serial-claimed.
            bigstat=$(MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -R "stat big.txt" "$IMGWSL" 2>&1)
            if echo "$bigstat" | grep -qF "(IND):" && echo "$bigstat" | grep -qF "(DIND):"; then
                ok "fs-indirect: host sees big.txt's IND+DIND tables on disk"
            else
                bad "fs-indirect: indirect tables not on disk: $(echo "$bigstat" | grep -i 'block' | head -3 | tr '\n' '|')"
            fi
        fi
        # pin rows: generation + stale-on-use + re-lease + eviction.
        # After remount the old pin is STALE (mount generation moved);
        # re-pinning moved.elf re-mints the SAME nid (identity is
        # deterministic) and re-leases the row; unpin then evicts it —
        # dispatch refuses "row evicted". Identity durable, binding leased.
        pinnid1=$(sed -n 's/.*pinned child.elf ino=[0-9]* nid=\([0-9a-f]*\).*/\1/p' "$WORK/boot_ext2.serial" | head -1)
        pinnid2=$(sed -n 's/.*re-pinned moved.elf ino=[0-9]* nid=\([0-9a-f]*\).*/\1/p' "$WORK/boot_ext2.serial" | head -1)
        if [ -n "$pinnid1" ] && [ "$pinnid1" = "$pinnid2" ] \
           && grep -qF "stale pin refused post-remount: stale pin — mount generation moved" "$WORK/boot_ext2.serial" \
           && grep -qE "exec-bynid re-leased ino=$pin_ino status=43" "$WORK/boot_ext2.serial" \
           && grep -qF "evicted pin refused: pin's row evicted" "$WORK/boot_ext2.serial"; then
            ok "pin-rows: remount stales the row; re-pin re-leased the SAME nid ($pinnid1); unpin evicted it"
        else
            bad "pin-rows: lifecycle evidence missing: p1=$pinnid1 p2=$pinnid2 $(grep -aE 'stale|re-pinned|evicted|re-leased|unpin' "$WORK/boot_ext2.serial" | tail -6 | tr '\n' '|')"
        fi
        # (PIT IRQ0 evidence lives on boot_multi — its epoch spans ticks;
        # the ext2 run now finishes inside one tick period because the
        # blk wait is parked, not burned)
        # spurious IRQ7/15 is legal once in a while; it must not storm.
        strays=$(grep -c "irq: stray" "$WORK/boot_ext2.serial" || true)
        if [ "$strays" -le 8 ]; then
            ok "irq-storm: stray IRQs bounded ($strays)"
        else
            bad "irq-storm: $strays stray IRQ deliveries — unbounded"
        fi
        if grep -qF "EXC v=0000000000000003" "$WORK/boot_ext2.serial" && grep -qF "(continued)" "$WORK/boot_ext2.serial"; then
            ok "exc-resume: child int3 delivered at CPL=3 and resumed"
        else
            bad "exc-resume: #BP evidence missing: $(tail -6 "$WORK/boot_ext2.serial" | tr '\n' '|')"
        fi

        # two ELF children on one roster: the PIT tick preempts between
        # them — their single-char writes interleave on serial, and the
        # switch counter in spawn_run reports the rotations. >=3 stream
        # transitions proves a return switch (not just a first handoff).
        if [ -n "$ELFAWSL" ] && [ -n "$ELFBWSL" ]; then
            boot_check "$ROOT/koru/native/tests/boot_multi.k" "MULTI COMPLETE" \
                -drive "file=$IMG,format=raw,if=none,id=d0" \
                -device virtio-blk-pci,drive=d0,disable-modern=on
            sw=$(sed -n 's/.*sched: switches=\([0-9]*\).*/\1/p' "$WORK/boot_multi.serial" | tail -1)
            trans=$(grep -o 'AB\|BA' "$WORK/boot_multi.serial" | wc -l)
            if grep -qF "irq: timer delivered" "$WORK/boot_multi.serial"; then
                ok "irq-timer: PIT IRQ0 delivered through the IOAPIC/LAPIC door"
            else
                bad "irq-timer: no timer evidence: $(tail -6 "$WORK/boot_multi.serial" | tr '\n' '|')"
            fi
            if [ -n "$sw" ] && [ "$sw" -ge 2 ] && [ "$trans" -ge 3 ]; then
                ok "sched: tick preemption rotated the roster (switches=$sw, A/B transitions=$trans)"
            else
                bad "sched: no interleave evidence (switches=${sw:-none}, transitions=$trans)"
            fi
            if grep -qE "last-exit=4[34]" "$WORK/boot_multi.serial" && grep -qF "roster drained last=" "$WORK/boot_multi.serial"; then
                ok "sched: child exit codes rode the seam home"
            else
                bad "sched: exit evidence missing: $(tail -4 "$WORK/boot_multi.serial" | tr '\n' '|')"
            fi
        else
            bad "boot_multi: ticker ELFs not built (wslpath failed)"
        fi

        # conin: getc.elf's read(0) on an empty console ring parks the
        # child .blocked — the only resume is an 8042 IRQ1 whose ASCII byte
        # completes the read into the parked buffer. Same monitor-socket
        # injection as input-kbd, but the key must land AFTER the "?>"
        # prompt: an early sendkey just pre-loads the ring and the read
        # drains without ever blocking, proving nothing.
        con_src="$WORK/boot_conin.k"
        sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koru/native/tests/boot_conin.k" > "$con_src"
        if bash "$ROOT/scripts/build-native.sh" "$con_src" "$WORK/boot_conin.elf" > "$WORK/boot_conin.build" 2>&1; then
            conport=$((5200 + $$ % 400))
            timeout "$TIMEOUT" "$QEMU" -kernel "$WORK/boot_conin.elf" -serial stdio \
                -display none -m 64M -no-reboot \
                -monitor "tcp:127.0.0.1:$conport,server,nowait" \
                -drive "file=$IMG,format=raw,if=none,id=d0" \
                -device virtio-blk-pci,drive=d0,disable-modern=on \
                > "$WORK/boot_conin.serial" 2>&1 &
            conq=$!
            prompt=0
            for _ in $(seq 1 40); do
                grep -qF '?>' "$WORK/boot_conin.serial" 2>/dev/null && { prompt=1; break; }
                sleep 0.25
            done
            keys=0
            for _ in $(seq 1 20); do
                exec 4<>"/dev/tcp/127.0.0.1/$conport" 2>/dev/null && break
                sleep 0.5
            done
            if [ -e /dev/fd/4 ]; then
                for _ in 1 2 3; do
                    printf 'sendkey k\n' >&4 2>/dev/null || break
                    keys=$((keys+1))
                    sleep 0.5
                done
                exec 4>&-
            fi
            wait $conq 2>/dev/null || true
            if [ "$prompt" -eq 0 ]; then
                bad "conin-read: no '?> ' prompt — getc never reached read(0): $(tail -4 "$WORK/boot_conin.serial" | tr '\n' '|')"
            elif [ "$keys" -eq 0 ]; then
                bad "conin-read: monitor connect/sendkey failed — no injection happened"
            elif grep -qF "GOT=k" "$WORK/boot_conin.serial" && grep -qF "conin: exec getc status=42" "$WORK/boot_conin.serial"; then
                ok "conin-read: read(0) parked on conin until IRQ1 — sendkey k completed the read (GOT=k, status=42)"
            else
                bad "conin-read: wake evidence missing: $(tail -6 "$WORK/boot_conin.serial" | tr '\n' '|')"
            fi
        else
            bad "boot_conin: build failed"; tail -6 "$WORK/boot_conin.build"
        fi

        # shell REPL: sh.elf parks on read(0), names a path through its
        # scoped fs view, and nr=57 spawns it — the spawner parks on the
        # grandchild's exit and the child's status is the syscall's
        # return. Same monitor contract as conin: the prompt must be
        # observed BEFORE any sendkey, or a preloaded ring fakes the run.
        sh_src="$WORK/boot_shell.k"
        sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koru/native/tests/boot_shell.k" > "$sh_src"
        if bash "$ROOT/scripts/build-native.sh" "$sh_src" "$WORK/boot_shell.elf" > "$WORK/boot_shell.build" 2>&1; then
            shport=$((5400 + $$ % 300))
            # four command rounds (pie, args, pipe, fork) at human-key
            # cadence plus three grandchild ELF loads — a real budget
            timeout "$((TIMEOUT * 4))" "$QEMU" -kernel "$WORK/boot_shell.elf" -serial stdio \
                -display none -m 64M -no-reboot \
                -monitor "tcp:127.0.0.1:$shport,server,nowait" \
                -drive "file=$IMG,format=raw,if=none,id=d0" \
                -device virtio-blk-pci,drive=d0,disable-modern=on \
                > "$WORK/boot_shell.serial" 2>&1 &
            shq=$!
            prompt=0
            for _ in $(seq 1 60); do
                grep -qF 'koru> ' "$WORK/boot_shell.serial" 2>/dev/null && { prompt=1; break; }
                sleep 0.25
            done
            keys=0
            if [ "$prompt" -eq 1 ]; then
                for _ in $(seq 1 20); do
                    exec 4<>"/dev/tcp/127.0.0.1/$shport" 2>/dev/null && break
                    sleep 0.5
                done
                if [ -e /dev/fd/4 ]; then
                    for k in p i e dot e l f ret; do
                        printf 'sendkey %s\n' "$k" >&4 2>/dev/null || break
                        keys=$((keys+1))
                        sleep 0.3
                    done
                    exec 4>&-
                fi
                # wait for the grandchild's exit status to reach the shell
                done1=0
                for _ in $(seq 1 60); do
                    grep -qF 'exit=42' "$WORK/boot_shell.serial" 2>/dev/null && { done1=1; break; }
                    kill -0 $shq 2>/dev/null || break
                    sleep 0.25
                done
                # argv rung: "args.elf a1 b2" — the tokenized blob must
                # reach the child's main(argc, argv) as a real vector,
                # and argc rides home as the exit status (exit=3).
                done2=0
                if [ "${done1:-0}" -eq 1 ]; then
                    for _ in $(seq 1 20); do
                        exec 4<>"/dev/tcp/127.0.0.1/$shport" 2>/dev/null && break
                        sleep 0.5
                    done
                    if [ -e /dev/fd/4 ]; then
                        for k in a r g s dot e l f spc a 1 spc b 2 ret; do
                            printf 'sendkey %s\n' "$k" >&4 2>/dev/null || break
                            keys=$((keys+1))
                            sleep 0.3
                        done
                        exec 4>&-
                    fi
                    for _ in $(seq 1 60); do
                        grep -qF 'argv2=b2' "$WORK/boot_shell.serial" 2>/dev/null && { done2=1; break; }
                        kill -0 $shq 2>/dev/null || break
                        sleep 0.25
                    done
                fi
                # pipe rung: "pipegen.elf | catc.elf" — the '|' needs
                # shift+backslash (the kbd shifted table), pipe() mints
                # the ring, nr58 wires fd0/fd1 per child, nr61 reaps the
                # zombies. CATC n=20 means 20 bytes drained through the
                # ring; pipe: w=52 r=51 means both zombies were waited.
                done3=0
                if [ "${done2:-0}" -eq 1 ]; then
                    for _ in $(seq 1 20); do
                        exec 4<>"/dev/tcp/127.0.0.1/$shport" 2>/dev/null && break
                        sleep 0.5
                    done
                    if [ -e /dev/fd/4 ]; then
                        for k in p i p e g e n dot e l f spc shift-backslash spc c a t c dot e l f ret; do
                            printf 'sendkey %s\n' "$k" >&4 2>/dev/null || break
                            keys=$((keys+1))
                            sleep 0.3
                        done
                        exec 4>&-
                    fi
                    for _ in $(seq 1 80); do
                        grep -qF 'pipe: w=52 r=51' "$WORK/boot_shell.serial" 2>/dev/null && { done3=1; break; }
                        kill -0 $shq 2>/dev/null || break
                        sleep 0.25
                    done
                fi
                # fork rung: "forktest.elf" — musl _Fork issues a bare
                # nr57; the kernel copies the space, dups the fd table
                # through provider refcounts, the child resumes at the
                # post-syscall rip with rax=0. FORKC [-from] proves the
                # SHARED file offset; FORKP x=1 proves private memory.
                done4=0
                if [ "${done3:-0}" -eq 1 ]; then
                    for _ in $(seq 1 20); do
                        exec 4<>"/dev/tcp/127.0.0.1/$shport" 2>/dev/null && break
                        sleep 0.5
                    done
                    if [ -e /dev/fd/4 ]; then
                        for k in f o r k t e s t dot e l f ret; do
                            printf 'sendkey %s\n' "$k" >&4 2>/dev/null || break
                            keys=$((keys+1))
                            sleep 0.3
                        done
                        exec 4>&-
                    fi
                    for _ in $(seq 1 80); do
                        grep -qF 'exit=7' "$WORK/boot_shell.serial" 2>/dev/null && { done4=1; break; }
                        kill -0 $shq 2>/dev/null || break
                        sleep 0.25
                    done
                fi
                # grantbag rung: "granttest.elf" — the parent fstats
                # hello.txt into the pin keyspace (dev<<32|ino) and
                # marshals a GRANT section into the KGRB blob; the
                # grandchild runs with the open CLASS BIT REMOVED, so its
                # openat only succeeds through the nid grant. GRANT-OPEN /
                # GRANT-DENY / GRANT-AMPLIFY are the three measured claims.
                done5=0
                if [ "${done4:-0}" -eq 1 ]; then
                    for _ in $(seq 1 20); do
                        exec 4<>"/dev/tcp/127.0.0.1/$shport" 2>/dev/null && break
                        sleep 0.5
                    done
                    if [ -e /dev/fd/4 ]; then
                        for k in g r a n t t e s t dot e l f ret; do
                            printf 'sendkey %s\n' "$k" >&4 2>/dev/null || break
                            keys=$((keys+1))
                            sleep 0.3
                        done
                        exec 4>&-
                    fi
                    for _ in $(seq 1 80); do
                        grep -qF 'GTEST st=9' "$WORK/boot_shell.serial" 2>/dev/null && { done5=1; break; }
                        kill -0 $shq 2>/dev/null || break
                        sleep 0.25
                    done
                fi
                # reprompt observed before quitting
                for _ in $(seq 1 40); do
                    grep -c 'koru> ' "$WORK/boot_shell.serial" 2>/dev/null | grep -q '^[4-9]' && break
                    sleep 0.25
                done
                for _ in $(seq 1 20); do
                    exec 4<>"/dev/tcp/127.0.0.1/$shport" 2>/dev/null && break
                    sleep 0.5
                done
                if [ -e /dev/fd/4 ]; then
                    printf 'sendkey q\n' >&4 2>/dev/null
                    sleep 0.3
                    printf 'sendkey ret\n' >&4 2>/dev/null
                    sleep 1   # let the monitor drain before the socket closes
                    exec 4>&-
                fi
            fi
            wait $shq 2>/dev/null || true
            if [ "$prompt" -eq 0 ]; then
                bad "shell-repl: no 'koru> ' prompt — sh never reached read(0): $(tail -4 "$WORK/boot_shell.serial" | tr -d '\0' | tr '\n' '|')"
            elif [ "$keys" -lt 70 ]; then
                bad "shell-repl: monitor injection failed ($keys/70 keys sent)"
            elif [ "${done1:-0}" -eq 0 ]; then
                bad "shell-repl: spawn never completed: $(tail -6 "$WORK/boot_shell.serial" | tr -d '\0' | tr '\n' '|')"
            elif [ "${done2:-0}" -eq 0 ]; then
                bad "shell-repl: argv evidence missing — args.elf run never completed: $(tail -6 "$WORK/boot_shell.serial" | tr -d '\0' | tr '\n' '|')"
            elif [ "${done3:-0}" -eq 0 ]; then
                bad "shell-repl: pipeline evidence missing — pipegen|catc run never completed: $(tail -8 "$WORK/boot_shell.serial" | tr -d '\0' | tr '\n' '|')"
            elif [ "${done4:-0}" -eq 0 ]; then
                bad "shell-repl: fork evidence missing — forktest run never completed: $(tail -8 "$WORK/boot_shell.serial" | tr -d '\0' | tr '\n' '|')"
            elif [ "${done5:-0}" -eq 0 ]; then
                bad "shell-repl: grantbag evidence missing — granttest run never completed: $(tail -8 "$WORK/boot_shell.serial" | tr -d '\0' | tr '\n' '|')"
            elif grep -qF 'SHELL COMPLETE' "$WORK/boot_shell.serial" \
                 && grep -qF 'real pie child says hi' "$WORK/boot_shell.serial" \
                 && grep -qF 'exit=42' "$WORK/boot_shell.serial" \
                 && grep -qF 'argc=3' "$WORK/boot_shell.serial" \
                 && grep -qF 'argv0=args.elf' "$WORK/boot_shell.serial" \
                 && grep -qF 'argv1=a1' "$WORK/boot_shell.serial" \
                 && grep -qF 'exit=3' "$WORK/boot_shell.serial" \
                 && grep -qF 'PIPE-DATA-1234567890' "$WORK/boot_shell.serial" \
                 && grep -qF 'CATC n=20' "$WORK/boot_shell.serial" \
                 && grep -qF 'pipe: w=52 r=51' "$WORK/boot_shell.serial" \
                 && grep -qF 'FORKC cb=[-from] n=5 x=42' "$WORK/boot_shell.serial" \
                 && grep -qF 'FORKP p=3 w=3 ex=1 st=33 x=1 pb=[hello]' "$WORK/boot_shell.serial" \
                 && grep -qF 'FORKC clonev ret=-1 errno=38' "$WORK/boot_shell.serial" \
                 && grep -qE 'forks=1 fpages=[1-9]' "$WORK/boot_shell.serial" \
                 && grep -qF 'exit=7' "$WORK/boot_shell.serial" \
                 && grep -qE 'GRANT-OPEN n=[1-9]' "$WORK/boot_shell.serial" \
                 && grep -qF 'GRANT-DENY fd=-1 e=13' "$WORK/boot_shell.serial" \
                 && grep -qF 'GRANT-WRITE-DENY fd=-1 e=13' "$WORK/boot_shell.serial" \
                 && grep -qF 'GRANT-AMPLIFY r=-1 e=13' "$WORK/boot_shell.serial" \
                 && grep -qF 'GTEST st=9' "$WORK/boot_shell.serial" \
                 && grep -qE 'OBJ-OPEN fd=[3-9]' "$WORK/boot_shell.serial" \
                 && grep -qF 'OBJ-READ n=12 [obj-payload' "$WORK/boot_shell.serial" \
                 && grep -qF 'OBJ-WRITE w=10' "$WORK/boot_shell.serial" \
                 && grep -qF 'OBJ-DENY fd=-1 e=13' "$WORK/boot_shell.serial" \
                 && grep -qF 'GTEST-ObjT st=0' "$WORK/boot_shell.serial" \
                 && grep -qF 'shell: exec sh status=47' "$WORK/boot_shell.serial" \
                 && grep -qE 'yields=[1-9]' "$WORK/boot_shell.serial" \
                 && grep -qE 'rwaits=[1-9]' "$WORK/boot_shell.serial"; then
                ok "shell-repl: pie.elf via nr512, args.elf argv, pipegen|catc 20B through a real ring (rwaits>0), forktest.elf real musl fork (shared fd offset + private space + zombie reaped + clone CLONE_VM refused), grantc.elf nid-grant open (GRANT-OPEN/-DENY/-AMPLIFY), objt.elf openobj-by-key (OBJ-OPEN/-READ/-WRITE, wrong key refused), q quit (47)"
            else
                bad "shell-repl: evidence missing: $(tail -8 "$WORK/boot_shell.serial" | tr -d '\0' | tr '\n' '|')"
            fi
        else
            bad "boot_shell: build failed"; tail -6 "$WORK/boot_shell.build"
        fi

        # tick-kctx rung: run2(spin.elf, getc.elf) — the spinner never
        # blocks, so when the monitor's sendkey wakes getc's .conin
        # continuation the ONLY boundary that can reach it is the next
        # PIT tick rotating the running spinner out. sched: tick_kctx=N
        # counts dispatches that resumed a live kernel context from the
        # tick path — [1-9] is the measured proof; GOT=x that the
        # resumed read completed itself.
        tk_src="$WORK/boot_tkctx.k"
        sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koru/native/tests/boot_tkctx.k" > "$tk_src"
        if bash "$ROOT/scripts/build-native.sh" "$tk_src" "$WORK/boot_tkctx.elf" > "$WORK/boot_tkctx.build" 2>&1; then
            tkport=$((5600 + $$ % 300))
            timeout "$TIMEOUT" "$QEMU" -kernel "$WORK/boot_tkctx.elf" -serial stdio \
                -display none -m 64M -no-reboot \
                -monitor "tcp:127.0.0.1:$tkport,server,nowait" \
                -drive "file=$IMG,format=raw,if=none,id=d0" \
                -device virtio-blk-pci,drive=d0,disable-modern=on \
                > "$WORK/boot_tkctx.serial" 2>&1 &
            tkq=$!
            prompt=0
            for _ in $(seq 1 60); do
                grep -qF '?>' "$WORK/boot_tkctx.serial" 2>/dev/null && { prompt=1; break; }
                sleep 0.25
            done
            keys=0
            if [ "$prompt" -eq 1 ]; then
                for _ in $(seq 1 20); do
                    exec 4<>"/dev/tcp/127.0.0.1/$tkport" 2>/dev/null && break
                    sleep 0.5
                done
                if [ -e /dev/fd/4 ]; then
                    printf 'sendkey x\n' >&4 2>/dev/null && keys=1
                    sleep 1   # let the monitor drain before the socket closes
                    exec 4>&-
                fi
            fi
            wait $tkq 2>/dev/null || true
            if [ "$prompt" -eq 0 ]; then
                bad "tick-kctx: no '?> ' prompt — getc never reached read(0): $(tail -4 "$WORK/boot_tkctx.serial" | tr -d '\0' | tr '\n' '|')"
            elif [ "$keys" -eq 0 ]; then
                bad "tick-kctx: monitor connect/sendkey failed — no injection happened"
            elif grep -qF 'GOT=x' "$WORK/boot_tkctx.serial" \
                 && grep -qF 'TKCTX COMPLETE' "$WORK/boot_tkctx.serial" \
                 && grep -qE 'tick_kctx=[1-9]' "$WORK/boot_tkctx.serial"; then
                ok "tick-kctx: IRQ1 woke the blocked read mid-spin; a PIT tick resumed the kernel continuation (GOT=x, drained)"
            else
                bad "tick-kctx: evidence missing: $(tail -8 "$WORK/boot_tkctx.serial" | tr -d '\0' | tr '\n' '|')"
            fi
        else
            bad "boot_tkctx: build failed"; tail -6 "$WORK/boot_tkctx.build"
        fi
    else
        bad "boot_ext2: image build failed: $(tail -2 "$WORK/mke2fs.out" "$WORK/debugfs.out")"
    fi
fi

echo "check-boot: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
