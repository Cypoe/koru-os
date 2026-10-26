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
TIMEOUT="${TIMEOUT:-15}"
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

# surf: koruos/surface on the native arm — surf.zig pools provider-owned
# backing (contiguous pmm frames), cascades placement like a dumb WM,
# blits damage through fb and commits through fb:present. Serial proves
# the seam (open/fill/present/close + the empty-damage refusal); the
# screendump proves the pixels — surf0's magenta rect, surf1's cyan ON
# TOP (present order is the z-rule), background untouched. This row's
# whole point: serial self-report alone passed while the TRANSFER offset
# bug misplaced every sub-rect — pixels or it didn't happen.
surf_src="$WORK/boot_surf.k"
sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koru/surface/tests/boot_surf.k" > "$surf_src"
if bash "$ROOT/scripts/build-native.sh" "$surf_src" "$WORK/boot_surf.elf" > "$WORK/boot_surf.build" 2>&1; then
    surfport=$((5600 + $$ % 400))
    surfppm="$WORK/surf.ppm"
    surfppmw="$(cygpath -m "$surfppm" 2>/dev/null || echo "$surfppm")"
    timeout "$TIMEOUT" "$QEMU" -kernel "$WORK/boot_surf.elf" -serial stdio \
        -display none -m 64M -no-reboot -vga none -device virtio-gpu-pci \
        -monitor "tcp:127.0.0.1:$surfport,server,nowait" \
        > "$WORK/boot_surf.serial" 2>&1 &
    sq=$!
    for _ in $(seq 1 20); do
        exec 3<>"/dev/tcp/127.0.0.1/$surfport" 2>/dev/null && break
        sleep 0.5
    done
    sdumped=0
    if [ -e /dev/fd/3 ]; then
        for _ in $(seq 1 30); do
            if grep -qF "SURF COMPLETE" "$WORK/boot_surf.serial" 2>/dev/null; then
                printf 'screendump %s\n' "$surfppmw" >&3 2>/dev/null && sdumped=1
                break
            fi
            sleep 0.5
        done
        sleep 0.5
        exec 3>&-
    fi
    kill $sq 2>/dev/null
    wait $sq 2>/dev/null || true
    if grep -qF "surf: open 320x200 at 24,24" "$WORK/boot_surf.serial" \
       && grep -qF "surf: open 160x100 at 80,64" "$WORK/boot_surf.serial" \
       && grep -qF "empty damage refused" "$WORK/boot_surf.serial" \
       && grep -qF "SURF COMPLETE" "$WORK/boot_surf.serial"; then
        ok "surf-native: *Surf<open!> minted/filled/presented/closed; empty damage refused"
    else
        bad "surf-native: seam evidence missing: $(grep -aE 'surf|FAIL|EXC' "$WORK/boot_surf.serial" | tail -6 | tr '\n' '|')"
    fi
    if [ "$sdumped" -eq 1 ] && [ -s "$surfppm" ]; then
        if command -v python >/dev/null 2>&1 && python -c "
import sys,re
d=open(sys.argv[1],'rb').read()
m=re.match(rb'P6\s+(\d+)\s+(\d+)\s+(\d+)\s', d)
w,h,_=map(int,m.groups()); o=m.end()
px=lambda x,y: d[o+(y*w+x)*3:o+(y*w+x)*3+3]
# surf0 magenta at (24,24)+320x200; surf1 cyan at (80,64)+160x100 on top
sys.exit(0 if px(30,30)==b'\xff\x00\xff' and px(300,200)==b'\xff\x00\xff'
         and px(160,114)==b'\x00\xff\xff' and px(8,8)==b'\x00\x00\x00' else 1)
" "$(cygpath -w "$surfppm")"; then
            ok "surf-pixels: screendump shows magenta + cyan rects at their cascaded slots"
        else
            bad "surf-pixels: dump present but pixels wrong (or python missing)"
        fi
    else
        bad "surf-pixels: screendump failed — dumped=$sdumped ppm=$([ -s "$surfppm" ] && echo written || echo missing)"
    fi
else
    bad "boot_surf: build failed"; tail -6 "$WORK/boot_surf.build"
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
        # kept its (dev,ino) key across the rename. WTEST-BIG: 40 KiB in
        # one write crosses single-indirect (k=12..39); an lseek to
        # 300 KiB + write crosses double-indirect (k=300 → leaf); the
        # sparse tail reads back through the same tables.
        if grep -qE "WTEST w=[0-9]+ rb=[0-9]+ ino=[0-9a-fx]+ renamed=1 same-ino=[0-9]+ unl=1 dot=1 DONE" "$WORK/boot_ext2.serial" \
           && grep -qE "WTEST-BIG w=40960 rb=40960 sz=307205 sum=[0-9a-f]+ mism=0 DONE" "$WORK/boot_ext2.serial" \
           && ! grep -qF "WTEST-FAIL" "$WORK/boot_ext2.serial" \
           && grep -qF "exec wtest.elf status=0" "$WORK/boot_ext2.serial"; then
            ok "fs-write: musl child created/wrote/renamed/unlinked via the scoped view; 40KiB+300KiB-sparse through IND+DIND tables"
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
                ok "irq-timer: PIT IRQ0 delivered through the PIC"
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
