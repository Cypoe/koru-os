#!/usr/bin/env bash
# Build a koru-os image with the obligation-derived kconfig (koruos/realize) instead of
# koru-libs' `unikraft gen`. Usage: build-realized.sh <slice|silo> <koru-libs @ ff5cb559> <workdir> [order-override]
# In the work copy only, the boot program gets `import koruos/realize` and loses the
# hand-written allocator lines (they are now derived). Everything else is unchanged.
set -euo pipefail
WHICH=$1; LIBS=$2; W=$3; OVR=${4:-}; REPO=$(cd "$(dirname "$0")/../.." && pwd)
case $WHICH in
  slice) BOOT=boot_slice.k; SYM=ukplat_monotonic_clock ;;
  silo)  BOOT=boot_silo.k;  SYM=none ;;
  *) echo "unknown $WHICH"; exit 2 ;;
esac
if [ $WHICH = slice ]; then
  "$REPO/experiments/slice-a/build-slice.sh" "$LIBS" "$W" > /dev/null 2>&1 || true   # fills artifact ids; its own build is discarded
  rm -rf "$W/koruos/slice/tests/.unikraft" "$W/koruos/slice/tests/.config.koru_qemu-x86_64" "$W/koruos/slice/tests/Kraftfile"
else
  rm -rf "$W"; mkdir -p "$W/koruos"; cp -R "$REPO/koru/silo" "$W/koruos/"; cp -R "$LIBS/unikraft" "$W/"
fi
cp -R "$REPO/koru/realize" "$W/koruos/"
T="$W/koruos/$WHICH/tests"; cd "$T"
python3 - "$BOOT" <<'PY'
import re, sys
f = sys.argv[1]; t = open(f).read()
t = t.replace("import unikraft\n", "import unikraft\nimport koruos/realize\n", 1)
t = re.sub(r"\n\s*CONFIG_LIBUKALLOC: 'y'", "", t)
t = re.sub(r"\n\s*CONFIG_LIBUKALLOCBBUDDY: 'y'", "", t)
open(f, "w").write(t)
PY
koruc $BOOT realize gen
if [ -n "$OVR" ]; then sed -i "s/CONFIG_STACK_SIZE_PAGE_ORDER: '[0-9]*'/CONFIG_STACK_SIZE_PAGE_ORDER: '$OVR'/" Kraftfile; echo "OVERRIDE stack order $OVR (probe only)" >> realize.txt; fi
rm -f output_emitted.zig
koruc $BOOT > koruc-emit.log 2>&1 || true
if grep -q error koruc-emit.log && ! grep -q "undefined symbol: $SYM" koruc-emit.log; then cat koruc-emit.log; exit 1; fi
test -s output_emitted.zig
zig build-lib wrapper.zig -target x86_64-freestanding -O ReleaseSmall -fno-stack-protector -femit-bin=libkoruapp.a
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt --log-type basic
ls -la .unikraft/build/koru_qemu-x86_64
