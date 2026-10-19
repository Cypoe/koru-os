#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
W=${W:-/workspace/msmmu}
W_SRC=${W_SRC:-/workspace/m3img}
export PATH=/workspace/tc/kraft:$PATH
mkdir -p "$W" && cd "$W"
cp "$HERE/app/Kraftfile" "$HERE/app/Makefile.uk" "$HERE/app/Config.uk" "$HERE/app/main.c" .
cp "$REPO/lib/koruspawn/mmu.c" "$REPO/lib/koruspawn/mmu.h" .
if [ ! -d .unikraft/unikraft ]; then
  mkdir -p .unikraft
  cp -a "$W_SRC/.unikraft/unikraft" "$W_SRC/.unikraft/libs" .unikraft/
fi
P="$HERE/patches/unikraft-0.21-sched-cr3-switch.patch"
grep -q ksp_mmu_sched_switch .unikraft/unikraft/lib/uksched/include/uk/sched_impl.h 2>/dev/null || \
  patch -d .unikraft/unikraft -p1 < "$P"
rm -f .config.m-spawn-mmu_qemu-x86_64 .unikraft/build/config
rm -f .unikraft/build/appkoruos/*.o 2>/dev/null || true
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt --log-type basic
ls -la .unikraft/build/m-spawn-mmu_qemu-x86_64
sha256sum .unikraft/build/m-spawn-mmu_qemu-x86_64
