#!/usr/bin/env bash
# Build the Slice A unikernel: koruos/slice + boot_slice.k inside a Koru-built Unikraft image.
# Artifact identity of each provider (and of the task body) is the sha256 of its
# "// artifact-begin <name>" .. "// artifact-end <name>" block in koru/slice/index.kz;
# the build fills @@ART:<name>@@ in the work copy, never in the repo.
# Usage: build-slice.sh <koru-libs checkout @ ff5cb559> <workdir>
set -euo pipefail
LIBS=$1; W=$2; REPO=$(cd "$(dirname "$0")/../.." && pwd)
rm -rf "$W"; mkdir -p "$W/koruos"
cp -R "$REPO/koru/slice" "$W/koruos/"; cp -R "$LIBS/unikraft" "$W/"
python3 - "$W/koruos/slice" <<'PY'
import hashlib, re, sys, pathlib
d = pathlib.Path(sys.argv[1])
src = (d / "index.kz").read_text()
arts = {}
for m in re.finditer(r"// artifact-begin (\S+)\n(.*?)// artifact-end \1\n", src, re.S):
    arts[m.group(1)] = hashlib.sha256(m.group(2).encode()).hexdigest()
for f in [d / "index.kz", d / "tests" / "boot_slice.k"]:
    t = f.read_text()
    for k, v in arts.items():
        t = t.replace("@@ART:%s@@" % k, v)
    left = re.findall(r"@@ART:[^@]+@@", t)
    if left: sys.exit("unfilled artifact tokens in %s: %s" % (f, left))
    f.write_text(t)
(d / "artifacts.txt").write_text("".join("%s %s\n" % (v, k) for k, v in sorted(arts.items())))
print("".join("artifact %s %s\n" % (k, v) for k, v in sorted(arts.items())), end="")
PY
cd "$W/koruos/slice/tests"
koruc boot_slice.k unikraft gen
# The host link of the second step fails on Unikraft symbols (ukplat_monotonic_clock);
# that is expected (koru-libs unikraft/sched README). output_emitted.zig must exist.
rm -f output_emitted.zig
koruc boot_slice.k > koruc-emit.log 2>&1 || true
grep -q "undefined symbol: ukplat_monotonic_clock" koruc-emit.log || ! grep -q "error" koruc-emit.log || { cat koruc-emit.log; exit 1; }
test -s output_emitted.zig
zig build-lib wrapper.zig -target x86_64-freestanding -O ReleaseSmall -fno-stack-protector -femit-bin=libkoruapp.a
UK_CFLAGS="-std=gnu17" kraft build --arch x86_64 --plat qemu --no-prompt --log-type basic
ls -la .unikraft/build/koru_qemu-x86_64 libkoruapp.a
