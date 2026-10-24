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
    if MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 64 -O none -L koru-native "$IMGWSL" 4096 > "$WORK/mke2fs.out" 2>&1 \
        && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "write $ELFWSL child.elf" "$IMGWSL" > "$WORK/debugfs.out" 2>&1 \
        && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -R "mkdir bin" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1 \
        && { printf 'cd bin\nwrite %s childA.elf\nwrite %s childB.elf\n' "$ELFAWSL" "$ELFBWSL" > "$WORK/debugfs.cmds" \
        && MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/debugfs -w -f "$(wsl -e wslpath -u "$(cygpath -w "$WORK/debugfs.cmds")")" "$IMGWSL" >> "$WORK/debugfs.out" 2>&1; }; then
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
        if grep -qF "SEAM REFUSE nr=0000000000000002" "$WORK/boot_ext2.serial" && grep -qF "getpid refused" "$WORK/boot_ext2.serial"; then
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
    else
        bad "boot_ext2: image build failed: $(tail -2 "$WORK/mke2fs.out" "$WORK/debugfs.out")"
    fi
fi

echo "check-boot: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
