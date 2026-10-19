#!/usr/bin/env bash
# Counted measurement for ACCEPTANCE.md R1-R6. Usage: run-counted.sh <koru-libs @ ff5cb559> <scratch> <evidence dir>
set -u
LIBS=$1; S=$2; E=$3; H=$(cd "$(dirname "$0")" && pwd); mkdir -p "$E"
for p in slice silo; do
  "$H/build-realized.sh" $p "$LIBS" "$S/$p" > "$S/$p-build.log" 2>&1; echo "build $p exit=$?"
  T="$S/$p/koruos/$p/tests"; K="$T/.unikraft/build/koru_qemu-x86_64"
  { echo "== $p"; rg -c "CONFIG_(LIBUKALLOC|STACK_SIZE|LIBUKSCHED|LIBUKBOOT_INITN?O?SCHED)" "$T/boot_$p.k" | sed 's/^/author-block hits (want none): /' || echo "author-block hits (want none): 0"
    cat "$T/realize.txt"; echo "-- Kraftfile"; cat "$T/Kraftfile"; } > "$E/$p-realize.txt"
  "$H/check-config.py" "$T" > "$E/$p-config.txt"; tail -1 "$E/$p-config.txt"
  "$H/stack-demand.py" "$K.dbg" $((4096 << $(sed -n "s/^CONFIG_STACK_SIZE_PAGE_ORDER=//p" "$T/.config.koru_qemu-x86_64"))) > "$E/$p-stack.txt"; tail -1 "$E/$p-stack.txt"
  { sha256sum "$K"; ls -l "$K" | awk '{print $5" B"}'; size "$K.dbg"; } > "$E/$p-kernel.txt"
done
"$H/../slice-a/check-negatives.sh" "$S/slice" > "$E/slice-compile-gates.txt" 2>&1; tail -1 "$E/slice-compile-gates.txt"
for i in 1 2 3; do
  "$H/../slice-a/run-slice.py" "$S/slice/koruos/slice/tests/.unikraft/build/koru_qemu-x86_64" "$S/slice-run-$i" > /dev/null 2>&1
  "$H/../slice-a/check.py" "$S/slice-run-$i" "$S/slice/koruos/slice/artifacts.txt" "$E/slice-compile-gates.txt" > "$E/slice-run-$i.txt"; echo "slice run $i: $(tail -1 "$E/slice-run-$i.txt")"
  "$H/../ds0-silo/run-image.sh" "$S/silo/koruos/silo/tests/.unikraft/build/koru_qemu-x86_64" "$S/ds0-run-$i" > "$E/ds0-run-$i.txt"; echo "ds0 run $i: $(tail -1 "$E/ds0-run-$i.txt")"
done
"$H/check-negatives.sh" "$LIBS" "$S/neg" 2>&1 | rg -v '^(✓|Building|🔧)' > "$E/negatives.txt"; tail -1 "$E/negatives.txt"
