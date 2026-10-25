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

# fb: the koruos/fb seam over a BGA-programmed linear framebuffer — QEMU's
# built-in multiboot loader does not answer the mb2 fb request tag, so the
# provider programs the std VGA's VBE_DISPI registers itself and takes the
# LFB phys from PCI BAR0. Serial geometry is the gate; the three-band
# screen is human evidence (screendump). -display none still models the
# device, so no display is needed.
boot_check "$ROOT/koru/fb/tests/boot_fb.k" "FB COMPLETE" -vga std

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
ELFWSL=""
if command -v python >/dev/null 2>&1; then
    python "$ROOT/scripts/mk-child-elf.py" "$ELF" > /dev/null 2>&1
    python "$ROOT/scripts/mk-ticker-elf.py" "$ELFA" A 30 8000000 43 > /dev/null 2>&1
    python "$ROOT/scripts/mk-ticker-elf.py" "$ELFB" B 30 8000000 44 > /dev/null 2>&1
    ELFWSL="$(wsl -e wslpath -u "$(cygpath -w "$ELF")" 2>/dev/null)" || ELFWSL=""
    ELFAWSL="$(wsl -e wslpath -u "$(cygpath -w "$ELFA")" 2>/dev/null)" || ELFAWSL=""
    ELFBWSL="$(wsl -e wslpath -u "$(cygpath -w "$ELFB")" 2>/dev/null)" || ELFBWSL=""
elif command -v py >/dev/null 2>&1; then
    py -3 "$ROOT/scripts/mk-child-elf.py" "$(cygpath -w "$ELF")" > /dev/null 2>&1
    py -3 "$ROOT/scripts/mk-ticker-elf.py" "$(cygpath -w "$ELFA")" A 30 8000000 43 > /dev/null 2>&1
    py -3 "$ROOT/scripts/mk-ticker-elf.py" "$(cygpath -w "$ELFB")" B 30 8000000 44 > /dev/null 2>&1
    ELFWSL="$(wsl -e wslpath -u "$(cygpath -w "$ELF")" 2>/dev/null)" || ELFWSL=""
    ELFAWSL="$(wsl -e wslpath -u "$(cygpath -w "$ELFA")" 2>/dev/null)" || ELFAWSL=""
    ELFBWSL="$(wsl -e wslpath -u "$(cygpath -w "$ELFB")" 2>/dev/null)" || ELFBWSL=""
fi
if [ -z "$IMGWSL" ] || [ -z "$ELFWSL" ]; then
    bad "boot_ext2: WSL/wslpath or python unavailable — cannot build the ext2 image"
else
    if MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 128 -O none -L koru-native "$IMGWSL" 16384 > "$WORK/mke2fs.out" 2>&1 \
        && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $ELFWSL child.elf" "$IMGWSL" > "$WORK/debugfs.out" 2>&1 \
        && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "mkdir bin" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
        && { printf 'cd bin\nwrite %s childA.elf\nwrite %s childB.elf\n' "$ELFAWSL" "$ELFBWSL" > "$WORK/debugfs.cmds" \
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
        REALWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/realhello.c")")"
        PIEWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/pie.elf")")"
        MUSLWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/musl.elf")")"
        FSCATWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/fscat.elf")")"
        HELLOWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/hello.txt")")"
        GETCWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/getc.elf")")"
        SHWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/sh.elf")")"
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
           && "$ZIGBIN" build-lib -target x86_64-linux-musl -dynamic -O ReleaseSmall -femit-bin="$WORK/libhi.so" "$WORK/libhi.c" > "$WORK/hi.build" 2>&1 \
           && "$ZIGBIN" cc -target x86_64-linux-musl -dynamic -Wl,--image-base=0x48000000 -Wl,--build-id=none -s -o "$WORK/hi.elf" "$WORK/hi.c" "$WORK/libhi.so" >> "$WORK/hi.build" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $PIEWSL pie.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $MUSLWSL musl.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $FSCATWSL fscat.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $HELLOWSL hello.txt" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $GETCWSL getc.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
           && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $SHWSL sh.elf" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
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
            timeout "$TIMEOUT" "$QEMU" -kernel "$WORK/boot_shell.elf" -serial stdio \
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
                # reprompt observed before quitting
                for _ in $(seq 1 40); do
                    grep -c 'koru> ' "$WORK/boot_shell.serial" 2>/dev/null | grep -q '^[2-9]' && break
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
            elif [ "$keys" -lt 8 ]; then
                bad "shell-repl: monitor injection failed ($keys/8 keys sent)"
            elif [ "${done1:-0}" -eq 0 ]; then
                bad "shell-repl: spawn never completed: $(tail -6 "$WORK/boot_shell.serial" | tr -d '\0' | tr '\n' '|')"
            elif grep -qF 'SHELL COMPLETE' "$WORK/boot_shell.serial" \
                 && grep -qF 'real pie child says hi' "$WORK/boot_shell.serial" \
                 && grep -qF 'exit=42' "$WORK/boot_shell.serial" \
                 && grep -qF 'shell: exec sh status=47' "$WORK/boot_shell.serial"; then
                ok "shell-repl: sh spawned pie.elf via nr57 parked on exit (status 42 home), q quit (47)"
            else
                bad "shell-repl: evidence missing: $(tail -8 "$WORK/boot_shell.serial" | tr -d '\0' | tr '\n' '|')"
            fi
        else
            bad "boot_shell: build failed"; tail -6 "$WORK/boot_shell.build"
        fi
    else
        bad "boot_ext2: image build failed: $(tail -2 "$WORK/mke2fs.out" "$WORK/debugfs.out")"
    fi
fi

echo "check-boot: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
