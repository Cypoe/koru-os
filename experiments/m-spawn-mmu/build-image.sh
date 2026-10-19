#!/usr/bin/env bash
# Build M-SPAWN-MMU step-1 image (ukpaging clone + nofault). TCG later via run.sh.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
W=${W:-/workspace/msmmu}
W_SRC=${W_SRC:-/workspace/m3img}
export PATH=/workspace/tc/kraft:$PATH
mkdir -p "$W" && cd "$W"
cp "$HERE/app/Kraftfile" "$HERE/app/Makefile.uk" "$HERE/app/Config.uk" "$HERE/app/main.c" .
if [ ! -d .unikraft/unikraft ]; then
  [ -d "$W_SRC/.unikraft/unikraft" ] || { echo "need $W_SRC/.unikraft (run m3 build first)"; exit 1; }
  mkdir -p .unikraft
  cp -a "$W_SRC/.unikraft/unikraft" "$W_SRC/.unikraft/libs" .unikraft/
fi
rm -f .config.m-spawn-mmu_qemu-x86_64 .unikraft/build/config
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt --log-type basic
ls -la .unikraft/build/m-spawn-mmu_qemu-x86_64
sha256sum .unikraft/build/m-spawn-mmu_qemu-x86_64
