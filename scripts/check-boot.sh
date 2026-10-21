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
# aspace selftest runs in kmain on every boot — same-VA different-phys proof.
if grep -qF "ASPACE" "$WORK/boot_hello.serial" && grep -qF "DISTINCT" "$WORK/boot_hello.serial"; then
    ok "aspace: per-domain CR3 proven (same VA, different phys)"
else
    bad "aspace: selftest evidence missing: $(head -3 "$WORK/boot_hello.serial" | tr '\n' '|')"
fi
# ring3: user-space child in its own CR3 writes a marker, int 0x80 seam.
if grep -qF "RING3 OK" "$WORK/boot_hello.serial"; then
    ok "ring3: iretq to CPL=3, user marker, int 0x80 seam taken"
else
    bad "ring3: seam evidence missing: $(tail -3 "$WORK/boot_hello.serial" | tr '\n' '|')"
fi

# ext2 over the native virtio-blk provider: a blank host-made image, the
# guest does mount -> create -> verify -> unmount and must print COMPLETE.
IMG="$WORK/ext2.img"
IMGWSL="$(wsl -e wslpath -u "$(cygpath -w "$IMG")" 2>/dev/null)" || IMGWSL=""
if [ -z "$IMGWSL" ]; then
    bad "boot_ext2: WSL/wslpath unavailable — cannot build the ext2 image"
else
    if MSYS2_ARG_CONV_EXCL='*' wsl -e /usr/sbin/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 64 -O none -L koru-native "$IMGWSL" 4096 > "$WORK/mke2fs.out" 2>&1; then
        boot_check "$ROOT/koru/native/tests/boot_ext2.k" "EXT2N COMPLETE" \
            -drive "file=$IMG,format=raw,if=none,id=d0" \
            -device virtio-blk-pci,drive=d0,disable-modern=on
    else
        bad "boot_ext2: mke2fs failed: $(tail -2 "$WORK/mke2fs.out")"
    fi
fi

echo "check-boot: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
