#!/usr/bin/env bash
# build-m1.sh [out.elf] — koruc emit (if needed) + freestanding zig link
# for the M1 dumb-KMS kernel. macOS recipe per m0/net-telemetry baton:
# koruc writes output_emitted.zig NEXT TO the .k source (copy-to-temp
# breaks {{ ENTRY }}/../.. resolution), then zig build-exe with the
# full -M module list from scripts/build-native.sh.
set -u
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
WORK="$(cd "$(dirname "$0")" && pwd)"
KORUC="${KORUC:-$HOME/src/koru-cypoe/zig-out/bin/koruc}"
export KORU_STDLIB="${KORU_STDLIB:-$HOME/src/koru-cypoe/koru_std}"
ZIG="${ZIG:-/opt/homebrew/bin/zig}"
PROG="$ROOT/koru/fb/tests/boot_fb.k"
OUT="${1:-$WORK/m1.elf}"

# build version — the ISO/panel can name the exact commit it runs.
SHA="$(git -C "$ROOT" rev-parse --short=7 HEAD 2>/dev/null || echo nogit)"
DIRTY="$(git -C "$ROOT" status --porcelain koru/native 2>/dev/null | head -1)"
TAG="$SHA$([ -n "$DIRTY" ] && echo -dirty || echo '')"
cat > "$WORK/buildver.zig" <<EOF
pub const sha: [*:0]const u8 = "$TAG";
EOF

# koruc emit — idempotent; refresh each build so kernel-side .k deps
# can't go stale. Exit 1 at the final host link is EXPECTED (the
# koruos_fb_* externs only exist in the freestanding image).
(cd "$WORK" && "$KORUC" "$PROG" > koruc.out 2>&1) || true
[ -s "$ROOT/koru/fb/tests/output_emitted.zig" ] || {
    echo "build-m1: koruc did not emit output_emitted.zig"; tail -10 "$WORK/koruc.out"; exit 1;
}

"$ZIG" build-exe \
    -target x86_64-freestanding-none -mcpu=x86_64 \
    -O ReleaseSmall \
    -fno-entry -fno-stack-protector -mno-red-zone \
    -T "$ROOT/koru/native/link.ld" \
    --dep program --dep runtime --dep virtio --dep aspace --dep user --dep pmm --dep kbd --dep pci --dep mmio --dep virtiopci --dep mouse --dep comp --dep acpi --dep smp --dep ioapic --dep net --dep e1000e --dep buildver -Mroot="$ROOT/koru/native/boot.zig" \
    -Macpi="$ROOT/koru/native/acpi.zig" \
    --dep acpi --dep mmio --dep pci -Mioapic="$ROOT/koru/native/ioapic.zig" \
    --dep pmm --dep mmio --dep acpi -Msmp="$ROOT/koru/native/smp.zig" \
    --dep compiler_env -Mprogram="$ROOT/koru/fb/tests/output_emitted.zig" \
    -Mcompiler_env="$ROOT/koru/native/compiler_env.zig" \
    -Mruntime="$ROOT/koru/native/runtime.zig" \
    -Mpci="$ROOT/koru/native/pci.zig" \
    --dep pmm -Mmmio="$ROOT/koru/native/mmio.zig" \
    --dep pci --dep mmio -Mvirtiopci="$ROOT/koru/native/virtiopci.zig" \
    --dep pci -Mvirtio="$ROOT/koru/native/virtio.zig" \
    --dep pmm -Maspace="$ROOT/koru/native/aspace.zig" \
    --dep pmm --dep kbd --dep mmio --dep ioapic --dep smp -Muser="$ROOT/koru/native/user.zig" \
    -Mpmm="$ROOT/koru/native/pmm.zig" \
    --dep mouse --dep comp -Mkbd="$ROOT/koru/native/kbd.zig" \
    --dep kbd --dep net -Mmouse="$ROOT/koru/native/mouse.zig" \
    -Mcomp="$ROOT/koru/native/comp.zig" \
    --dep pci --dep mmio --dep pmm -Me1000e="$ROOT/koru/native/e1000e.zig" \
    -Mbuildver="$WORK/buildver.zig" \
    --dep e1000e --dep pci -Mnet="$ROOT/koru/native/net.zig" \
    -femit-bin="$OUT" || {
    echo "build-m1: zig link failed"; exit 1;
}
echo "build-m1: $OUT written"
