#!/usr/bin/env bash
# check-boot.sh — the boot tier: declaration truth is not boot truth.
#
# Builds a multiboot2/PVH ELF from a boot fixture (build-native.sh), runs it
# under QEMU -kernel, and asserts the program's own serial output. A green
# run is measured boot evidence — the emitted entry actually executed on the
# image — not a bound-row claim. Needs koruc + zig + QEMU; missing tools are
# failures, not skips.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QEMU="${QEMU:-/c/Program Files/qemu/qemu-system-x86_64.exe}"
TIMEOUT="${TIMEOUT:-15}"

pass=0; failn=0
ok()  { pass=$((pass+1));  echo "ok   $1"; }
bad() { failn=$((failn+1)); echo "FAIL $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# boot_check <fixture.k> <expected-substring>
boot_check() {
    local fixture="$1" want="$2" name
    name="$(basename "$fixture" .k)"
    bash "$ROOT/scripts/build-native.sh" "$fixture" "$WORK/$name.elf" > "$WORK/$name.build" 2>&1 || {
        bad "$name: build failed"; tail -4 "$WORK/$name.build"; return
    }
    if [ ! -x "$QEMU" ]; then bad "$name: QEMU not found at $QEMU"; return; fi
    timeout "$TIMEOUT" "$QEMU" -kernel "$WORK/$name.elf" -serial stdio \
        -display none -m 64M -no-reboot > "$WORK/$name.serial" 2>&1
    if grep -qF "$want" "$WORK/$name.serial"; then
        ok "$name: booted, serial says \"$want\""
    else
        bad "$name: expected \"$want\" on serial; got: $(head -3 "$WORK/$name.serial" | tr '\n' '|')"
    fi
}

boot_check "$ROOT/koru/native/tests/boot_hello.k" "KORU NATIVE BOOT OK"

echo "check-boot: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
