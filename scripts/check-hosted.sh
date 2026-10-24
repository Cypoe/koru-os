#!/usr/bin/env bash
# check-hosted.sh — the hosted/linux arm tier.
#
# Builds a static musl binary from a hosted fixture (build-hosted.sh),
# runs it under WSL with KORU_BLK0 pointing at a host-made ext2 image,
# and asserts the program's own output. The same lifts boot_ext2 gates
# on koru-native run here byte-identical — a green run is evidence that
# the seams hold on host primitives: file-backed blkdev, fork+execve
# spawn, a nid store that survives process death.
# Needs koruc + zig + WSL (Ubuntu, e2fsprogs) — missing tools are
# failures, not skips.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIG="${ZIG:-/w/tools/zig-0.15.1/zig.exe}"
export PATH="/w/tools/zig-0.15.1:$PATH"
FIX="$(cygpath -m "$ROOT/koru/hosted/tests" 2>/dev/null || echo "$ROOT/koru/hosted/tests")"
WSL_DISTRO="${WSL_DISTRO:-Ubuntu}"

pass=0; failn=0
ok()  { pass=$((pass+1));  echo "ok   $1"; }
bad() { failn=$((failn+1)); echo "FAIL $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- the child: a real linux ELF, static musl — execve'able on any host --
cat > "$WORK/child.zig" <<'EOF'
const std = @import("std");
pub fn main() u8 {
    const out = std.fs.File.stdout();
    out.writeAll("hosted child says hi\n") catch {};
    return 43;
}
EOF
"$ZIG" build-exe -target x86_64-linux-musl -O ReleaseSmall -lc -static \
    "$WORK/child.zig" -femit-bin="$WORK/child.elf" > "$WORK/child.build" 2>&1 || {
    bad "child: zig build failed"; tail -6 "$WORK/child.build"; echo "---"; echo "check-hosted: $pass passed, $failn failed"; exit 1; }

IMG="$WORK/ext2.img"
IMGWSL="$(wsl -e wslpath -u "$(cygpath -w "$IMG")" 2>/dev/null)" || IMGWSL=""
ELFWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK/child.elf")" 2>/dev/null)" || ELFWSL=""
WORKWSL="$(wsl -e wslpath -u "$(cygpath -w "$WORK")" 2>/dev/null)" || WORKWSL=""
if [ -z "$IMGWSL" ] || [ -z "$ELFWSL" ] || [ -z "$WORKWSL" ]; then
    bad "WSL/wslpath unavailable — cannot wire the hosted fixture"; echo "---"; echo "check-hosted: $pass passed, $failn failed"; exit 1;
fi

# --- the image: ext2 (same recipe as check-boot) carrying the linux ELF --
if ! MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e /usr/sbin/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 64 -O none -L koru-hosted "$IMGWSL" 4096 > "$WORK/mke2fs.out" 2>&1 \
   || ! MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e /usr/sbin/debugfs -w -R "write $ELFWSL child.elf" "$IMGWSL" > "$WORK/debugfs.out" 2>&1; then
    bad "ext2 image build failed"; cat "$WORK/mke2fs.out" "$WORK/debugfs.out" | tail -6; echo "---"; echo "check-hosted: $pass passed, $failn failed"; exit 1;
fi

# --- the program: hosted fixture → static musl binary ---------------------
sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koru/hosted/tests/hosted_ext2.k" > "$WORK/hosted_ext2.k"
bash "$ROOT/scripts/build-hosted.sh" "$WORK/hosted_ext2.k" "$WORK/hosted_ext2.bin" > "$WORK/hosted.build" 2>&1 || {
    bad "hosted_ext2: build failed"; tail -8 "$WORK/hosted.build"; echo "---"; echo "check-hosted: $pass passed, $failn failed"; exit 1; }

# --- run under WSL: file-backed blkdev + persistent nid store -------------
MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
    "cd '$WORKWSL' && KORU_BLK0='$IMGWSL' KORU_NID_STORE='./nid.store' ./hosted_ext2.bin" \
    > "$WORK/hosted.serial" 2>&1
RC=$?
if [ $RC -ne 0 ]; then
    bad "hosted_ext2: run rc=$RC"; tail -8 "$WORK/hosted.serial"
else
    if grep -qF "EXT2H COMPLETE" "$WORK/hosted.serial"; then
        ok "hosted_ext2: mount→create→verify→exec→pin→exec-nid→unmount"
    else
        bad "hosted_ext2: incomplete: $(tail -5 "$WORK/hosted.serial" | tr '\n' '|')"
    fi
fi

# exec-by-path names the identity (ino + minted nid) on the seam — same
# evidence shape as boot_ext2.
if grep -qE "ext2h: exec child.elf ino=[0-9]+ nid=[0-9a-f]+ status=43" "$WORK/hosted.serial"; then
    ok "exec-path: ELF-by-path bound inode+nid identity (status=43)"
else
    bad "exec-path: identity evidence missing: $(grep ext2h "$WORK/hosted.serial" | tail -3 | tr '\n' '|')"
fi

# the child ran twice, as a real host process: once by path, once by nid.
nhits=$(grep -cF "hosted child says hi" "$WORK/hosted.serial")
if [ "$nhits" -eq 2 ] && grep -qE "ext2h: exec-nid ino=[0-9]+ status=43" "$WORK/hosted.serial"; then
    ok "spawn: child ran twice via fork+execve (path + exec-nid)"
else
    bad "spawn: expected 2 child outputs, got $nhits"
fi

# pin re-mints exec's nid — identity derived from the object, on host too.
exnid=$(sed -n 's/.*exec child.elf ino=\([0-9]*\) nid=\([0-9a-f]*\).*/\1 \2/p' "$WORK/hosted.serial" | head -1)
pinnid=$(sed -n 's/.*pinned child.elf ino=\([0-9]*\) nid=\([0-9a-f]*\).*/\1 \2/p' "$WORK/hosted.serial" | head -1)
if [ -n "$exnid" ] && [ "$exnid" = "$pinnid" ]; then
    ok "nid-bind: pin re-minted exec's nid (ino=$(echo "$exnid" | cut -d' ' -f1))"
else
    bad "nid-bind: exec='$exnid' pin='$pinnid'"
fi

# persistence is the arm's claim: the store survives process death — the
# file exists and holds the ext2/d0 foreign name.
if [ -f "$WORK/nid.store" ] && grep -q "ext2/d0/" "$WORK/nid.store"; then
    ok "nid-store: identity persisted to disk ($WORK/nid.store)"
else
    bad "nid-store: missing or empty"
fi

# advisory, not silent: hosted spawn must SAY the bag isn't enforced.
if grep -qF "rights bag" "$WORK/hosted.serial" && grep -qF "advisory" "$WORK/hosted.serial"; then
    ok "spawn-bag: hosted says advisory, doesn't pretend enforcement"
else
    bad "spawn-bag: advisory note missing"
fi

echo "---"
echo "check-hosted: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
