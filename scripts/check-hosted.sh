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

# --- the system REPL -----------------------------------------------------
# repl.kz: a compiled koru program that reads terminal lines and runs each
# as a std/bridge turn against the registered "os" scope. The scope IS the
# language-level rights bag — unregistered tors refuse at dispatch. The fs
# is a bridge resource: verbs take opaque tokens, the pool resolves them to
# typed pointers, and a consumed token refuses by name afterwards.
sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koru/hosted/tests/repl.kz" > "$WORK/repl.kz"
bash "$ROOT/scripts/build-hosted.sh" "$WORK/repl.kz" "$WORK/repl.bin" > "$WORK/repl.build" 2>&1 || {
    bad "repl: build failed"; tail -8 "$WORK/repl.build"; echo "---"; echo "check-hosted: $pass passed, $failn failed"; exit 1; }

MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
    "cd '$WORKWSL' && printf 'lookup(fs: fs, path: \"child.elf\")\npin(fs: fs, path: \"child.elf\")\nexec(fs: fs, path: \"child.elf\")\nbogus()\nexecnid(fs: fs, nid: \"0\")\nunmount(fs: fs)\npin(fs: fs, path: \"child.elf\")\nquit()\n' | KORU_BLK0='$IMGWSL' KORU_NID_STORE='./nid.store' ./repl.bin" \
    > "$WORK/repl.serial" 2>&1
RC=$?
if [ $RC -ne 0 ]; then
    bad "repl: run rc=$RC"; tail -8 "$WORK/repl.serial"
else
    if grep -qF "koru-os repl" "$WORK/repl.serial" && grep -qF "bye" "$WORK/repl.serial"; then
        ok "repl: prompt→interpret→loop→quit on host terminal"
    else
        bad "repl: loop incomplete: $(tail -5 "$WORK/repl.serial" | tr '\n' '|')"
    fi
    if grep -qE 'held resource: fs = h:Fs:[0-9a-f]+' "$WORK/repl.serial"; then
        ok "repl-bridge: boot-mounted fs minted as a pool resource token"
    else
        bad "repl-bridge: no resource token at boot: $(head -4 "$WORK/repl.serial" | tr '\n' '|')"
    fi
    if grep -qF '"value":"ino=12"' "$WORK/repl.serial"; then
        ok "repl-bridge: session-bound token resolves to the typed fs across turns"
    else
        bad "repl-bridge: lookup(fs: fs) did not resolve: $(grep -m1 lookup -A0 "$WORK/repl.serial" | tr '\n' '|')"
    fi
    if grep -qE '"value":"ino=[0-9]+ nid=[0-9a-f]+"' "$WORK/repl.serial"; then
        ok "repl-scope: pin mints nid identity from interpreted source"
    else
        bad "repl-scope: pin evidence missing"
    fi
    if grep -qF "hosted child says hi" "$WORK/repl.serial" && grep -qE '"value":"status=43 ino=[0-9]+ nid=[0-9a-f]+"' "$WORK/repl.serial"; then
        ok "repl-exec: interpreted exec ran a real host child (status=43)"
    else
        bad "repl-exec: child did not run: $(grep -E 'exec|child' "$WORK/repl.serial" | tail -3 | tr '\n' '|')"
    fi
    if grep -qF "event-denied: bogus" "$WORK/repl.serial"; then
        ok "repl-refusal: unregistered tor refuses at dispatch (event-denied)"
    else
        bad "repl-refusal: bogus() did not refuse"
    fi
    if grep -qF "nid not bound" "$WORK/repl.serial"; then
        ok "repl-refusal: unbound nid refuses by name, not silently"
    else
        bad "repl-refusal: execnid(0) accepted or lost"
    fi
    if grep -qF '"value":"unmounted"' "$WORK/repl.serial"; then
        ok "repl-bridge: consume verb discharged the fs handle mid-session"
    else
        bad "repl-bridge: unmount(fs: fs) did not discharge"
    fi
    if grep -qF "names nothing the session holds" "$WORK/repl.serial"; then
        ok "repl-bridge: spent token refuses by name — no stale resolution"
    else
        bad "repl-bridge: stale token did not refuse: $(grep -F 'h:Fs' "$WORK/repl.serial" | tail -2 | tr '\n' '|')"
    fi
fi

# --- koruos/surface on hosted — X11/WSLg as the compositor oracle --------
# The surface lift is a bridge resource like the fs: surf() mints
# *Surf<open!> into the pool, fill/present borrow through the token,
# sclose consumes, and bridge close discharges a still-held surface
# through the real provider. Realization is a live X server (WSLg :0) —
# a compositor, not a file dump. The gate needs that server: absent is a
# failure, not a skip — same rule as the rest of this file.
sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koru/hosted/tests/repl-x11.kz" > "$WORK/repl-x11.kz"
bash "$ROOT/scripts/build-hosted.sh" "$WORK/repl-x11.kz" "$WORK/repl-x11.bin" linux-x11 > "$WORK/repl-x11.build" 2>&1 \
    && [ -s "$WORK/repl-x11.bin" ] \
    && ok "surface-x11: linux-x11 arm builds (dynamic glibc + staged libX11.so.6)" \
    || { bad "surface-x11: build failed"; tail -8 "$WORK/repl-x11.build"; }

XSIDE="$WORK/x11side"
mkdir -p "$XSIDE"
XSIDEWSL="$WORKWSL/x11side"
XOK=0
MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
    "DISPLAY=:0 xwininfo -root >/dev/null 2>&1" && XOK=1
if [ "$XOK" -eq 1 ]; then
    ok "surface-x11: live X server on DISPLAY=:0 (WSLg)"
else
    bad "surface-x11: no X server on DISPLAY=:0 — the hosted surface oracle needs a compositor"
fi

if [ "$XOK" -eq 1 ]; then
    # Session A: open → bind → fill → present → hold the window while
    # xwininfo asks the server, then sclose → stale refusal.
    MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
        "cd '$WORKWSL' && export DISPLAY=:0 KORU_BLK0='$IMGWSL' KORU_NID_STORE='./nid.store'
         { printf 'surf(width: 640, height: 480) | ok o |> bind(name: \"s\", value: o.surface)\nfill(surface: s, x: 0, y: 0, w: 640, h: 480, color: 16711680)\npresent(surface: s, x: 0, y: 0, w: 640, h: 480)\npresent(surface: s, x: 0, y: 0, w: 0, h: 0)\n'; sleep 4; printf 'sclose(surface: s)\npresent(surface: s, x: 0, y: 0, w: 10, h: 10)\nquit()\n'; } | ./repl-x11.bin > '$XSIDEWSL/sessA.log' 2>&1 &
         sleep 3
         xwininfo -name koru-os > '$XSIDEWSL/wininfo.txt' 2>&1 || true
         wait" > /dev/null 2>&1

    if grep -qF 'Map State: IsViewable' "$XSIDE/wininfo.txt" && grep -qF 'Width: 640' "$XSIDE/wininfo.txt"; then
        ok "surface-x11: compositor reports mapped 640x480 'koru-os' window"
    else
        bad "surface-x11: no mapped window on the server: $(tail -3 "$XSIDE/wininfo.txt" | tr '\n' '|')"
    fi
    if grep -qF '"value":"s"' "$XSIDE/sessA.log"; then
        ok "surface-x11: surf() minted *Surf<open!> into the bridge pool (bound 's')"
    else
        bad "surface-x11: open/bind failed: $(grep -m1 'koru>' "$XSIDE/sessA.log")"
    fi
    A_OKS=$(grep -cF 'unhandled-branch: ok' "$XSIDE/sessA.log")
    A_ERRS=$(grep -E 'dispatch-error|validation-error|refused' "$XSIDE/sessA.log" | grep -cvF -e 'names nothing' -e 'unhandled-branch: refused')
    if [ "$A_OKS" -ge 3 ] && [ "$A_ERRS" -eq 0 ]; then
        ok "surface-x11: fill/present/sclose dispatched through the pool token"
    else
        bad "surface-x11: borrow path broke: $(grep -E 'error|refused' "$XSIDE/sessA.log" | head -3 | tr '\n' '|')"
    fi
    if grep -qF "names nothing the session holds" "$XSIDE/sessA.log"; then
        ok "surface-x11: spent surface token refuses by name after sclose"
    else
        bad "surface-x11: stale surface token did not refuse"
    fi
    if grep -qF "unhandled-branch: refused" "$XSIDE/sessA.log"; then
        ok "surface-damage: present(w:0,h:0) refuses — commit means damage"
    else
        bad "surface-damage: empty damage rect did not refuse"
    fi

    # Session B: open and quit — bridge close must discharge the still-held
    # surface through the real provider verb, like the fs unmount.
    MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
        "cd '$WORKWSL' && printf 'surf(width: 320, height: 240)\nquit()\n' | DISPLAY=:0 KORU_BLK0='$IMGWSL' KORU_NID_STORE='./nid.store' ./repl-x11.bin" \
        > "$XSIDE/sessB.log" 2>&1
    if grep -qE "\[BRIDGE\] Invoked 'sclose' for handle 'h:Surf:[0-9a-f]+'" "$XSIDE/sessB.log"; then
        ok "surface-x11: bridge close discharges held surface via provider"
    else
        bad "surface-x11: unclosed surface not discharged: $(tail -4 "$XSIDE/sessB.log" | tr '\n' '|')"
    fi

    # painter — the koru-written compositor fixture: owns a surface,
    # composites its own layers, repaints on the server's expose demand,
    # presents per-rect damage, and exits on 'q'. xprobe.py (ctypes→libX11)
    # is the witness: window by name, XGetImage pixels (the composite must
    # be on the wire, not just in our buffer), XSendEvent drives 'q'.
    sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koru/hosted/tests/painter.kz" > "$WORK/painter.kz"
    if bash "$ROOT/scripts/build-hosted.sh" "$WORK/painter.kz" "$WORK/painter.bin" linux-x11 > "$WORK/painter.build" 2>&1; then
        cp "$ROOT/scripts/xprobe.py" "$XSIDE/xprobe.py"
        MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
            "cd '$WORKWSL' && (DISPLAY=:0 ./painter.bin > '$XSIDEWSL/painter.log' 2>&1 &) && sleep 3 && python3 '$XSIDEWSL/xprobe.py' > '$XSIDEWSL/probe.out' 2>&1; sleep 6; cat '$XSIDEWSL/probe.out'" \
            > /dev/null 2>&1
        if grep -qF 'bg@160,60 = 0x202040' "$XSIDE/probe.out" && grep -qF 'fgA@30,30 = 0xc04000' "$XSIDE/probe.out"; then
            ok "painter: composited layers landed on the server (bg + fg pixels read back)"
        else
            bad "painter: composite evidence missing: $(tail -4 "$XSIDE/probe.out" | tr '\n' '|')"
        fi
        if grep -qE 'PAINTER keys=[0-9]+ exposes=[1-9][0-9]* frames=[1-9]' "$XSIDE/painter.log"; then
            ok "painter: koru event loop — expose repaint honored, key through koruos/input"
        else
            bad "painter: event-loop evidence missing: $(tail -4 "$XSIDE/painter.log" | tr '\n' '|')"
        fi
    else
        bad "painter: build failed"; tail -6 "$WORK/painter.build"
    fi
fi

# --- hosted/freebsd (Capsicum arm) — build-check -------------------------
# We can't run a FreeBSD binary on this host; the check that matters here
# is the semantic one: the shared provider machinery + the same fixtures
# must compile and link for x86_64-freebsd — i.e. nothing in the seam
# silently assumes linux (musl, stdout-as-global, linux-only posix).
bash "$ROOT/scripts/build-hosted.sh" "$WORK/hosted_ext2.k" "$WORK/ext2_fbsd.bin" freebsd > "$WORK/fbsd_ext2.build" 2>&1 \
    && [ -s "$WORK/ext2_fbsd.bin" ] \
    && ok "freebsd-arm: hosted_ext2 links for x86_64-freebsd (Capsicum shim)" \
    || { bad "freebsd-arm: ext2 build failed"; tail -6 "$WORK/fbsd_ext2.build"; }

bash "$ROOT/scripts/build-hosted.sh" "$WORK/repl.kz" "$WORK/repl_fbsd.bin" freebsd > "$WORK/fbsd_repl.build" 2>&1 \
    && [ -s "$WORK/repl_fbsd.bin" ] \
    && ok "freebsd-arm: repl links for x86_64-freebsd (interpreter closure included)" \
    || { bad "freebsd-arm: repl build failed"; tail -6 "$WORK/fbsd_repl.build"; }

echo "---"
echo "check-hosted: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
