#!/usr/bin/env bash
# build-iso.sh — full M1 pipeline -> dist/koru-vbirq9-<shortsha>.iso
# The ISO filename IS the commit: flash koru-vbirq9-9f145d4.iso == commit
# 9f145d4. Both sides can trust it — no more 'which vbirq9 is this?'.
set -euo pipefail
WORK="$(cd "$(dirname "$0")" && pwd)"
SESSION="$(cd "$WORK/.." && pwd)"
ROOT="$(cd "$SESSION/../.." && pwd)"
SHA="$(git -C "$ROOT" rev-parse --short=7 HEAD)"
DIRTY="$(git -C "$ROOT" status --porcelain koru/native | head -1)"
# KORU_SCENARIO variants get their own ISO name — a self-driving image is
# not byte-identical to the plain commit build and must not share its tag.
SCEN="$(printf '%s' "${KORU_SCENARIO:-}" | tr -cd 'a-z0-9-')"
TAG="$SHA$([ -n "$DIRTY" ] && echo -dirty || echo '')$([ -n "$SCEN" ] && echo "-$SCEN" || echo '')"
ISO="$SESSION/dist/koru-vbirq9-$TAG.iso"

bash "$WORK/build-m1-small.sh" "$WORK/m1-vbirq9-small.elf"
cp "$WORK/m1-vbirq9-small.elf" "$SESSION/isotree/boot/koru.elf"
docker run --rm --platform linux/amd64 \
    -v "$SESSION/isotree:/iso:ro" -v "$SESSION/iso-out:/out" \
    koruos-amd64-img:latest \
    grub-mkrescue -o /out/koru.iso /iso >/dev/null 2>&1
python3 - "$SESSION/iso-out/koru.iso" "$ISO" <<'PY'
import sys
d = bytearray(open(sys.argv[1],'rb').read())
d[0x1BE]=0x83; d[0x1C2]=0x10; d[0x1C3:0x1C6]=b'\x00\x00\x00'
open(sys.argv[2],'wb').write(d)
PY
echo "ISO: $ISO  (commit $TAG)"
