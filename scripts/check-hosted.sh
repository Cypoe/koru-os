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
FIX="$(cygpath -m "$ROOT/koruos/hosted/tests" 2>/dev/null || echo "$ROOT/koruos/hosted/tests")"
WSL_DISTRO="${WSL_DISTRO:-Ubuntu}"

pass=0; failn=0
ok()  { pass=$((pass+1));  echo "ok   $1"; }
bad() { failn=$((failn+1)); echo "FAIL $1"; }

# Gate runs are evidence, not scratch: each run gets its own dir under
# evidence/runs/<ts>-hosted.XXXXXX (gitignored). EVIDENCE_KEEP prunes.
KEEP="${EVIDENCE_KEEP:-10}"
RUNS="$ROOT/evidence/runs"
mkdir -p "$RUNS"
WORK="$(mktemp -d "$RUNS/$(date +%Y%m%d-%H%M%S)-hosted.XXXXXX")"
# Build caches are not evidence — strip them on exit, keep logs/artifacts.
trap 'find "$WORK" -type d \( -name .zig-cache -o -name zig-out -o -name zig-cache \) -exec rm -rf {} + 2>/dev/null; echo "evidence: $WORK"' EXIT
find "$RUNS" -mindepth 1 -maxdepth 1 -type d -name '*-hosted.*' \
    | sort -r | tail -n +$((KEEP+1)) | xargs -r rm -rf

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
sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koruos/hosted/tests/hosted_ext2.k" > "$WORK/hosted_ext2.k"
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
        ok "hosted_ext2: mount→create→verify→exec→pin→exec-bynid→exec-nid→unmount"
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

# the child ran three times, as real host processes: by path, by nid with
# the pin resolving the provider through the mounted table, and by nid
# held in the caller's fs. The post-unmount call must refuse by name —
# the pin outlives the mount but a dead provider never executes.
nhits=$(grep -cF "hosted child says hi" "$WORK/hosted.serial")
if [ "$nhits" -eq 3 ] \
   && grep -qE "ext2h: exec-bynid dev=0 ino=[0-9]+ status=43" "$WORK/hosted.serial" \
   && grep -qF "ext2h: exec-bynid post-unmount refused:" "$WORK/hosted.serial" \
   && grep -qE "ext2h: exec-nid ino=[0-9]+ status=43" "$WORK/hosted.serial"; then
    ok "spawn: child ran 3x via fork+execve (path + exec-bynid + exec-nid); stale pin refused post-unmount"
else
    bad "spawn: expected 3 child outputs + bynid evidence + post-unmount refusal, got $nhits: $(grep -aE 'exec-bynid|exec-nid' "$WORK/hosted.serial" | tail -4 | tr '\n' '|')"
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
sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koruos/hosted/tests/repl.kz" > "$WORK/repl.kz"
bash "$ROOT/scripts/build-hosted.sh" "$WORK/repl.kz" "$WORK/repl.bin" > "$WORK/repl.build" 2>&1 || {
    bad "repl: build failed"; tail -8 "$WORK/repl.build"; echo "---"; echo "check-hosted: $pass passed, $failn failed"; exit 1; }

MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
    "cd '$WORKWSL' && printf 'lookup(fs: fs, path: \"child.elf\")\npin(fs: fs, path: \"child.elf\")\nexec(fs: fs, path: \"child.elf\")\nhostexec(path: \"/usr/bin/busybox\", args: \"echo koru-real-elf\", rights: 3)\nhostexec(path: \"/usr/bin/false\", args: \"\", rights: 3)\nbogus()\nexecnid(fs: fs, nid: \"0\")\nunmount(fs: fs)\npin(fs: fs, path: \"child.elf\")\nquit()\n' | KORU_BLK0='$IMGWSL' KORU_NID_STORE='./nid.store' ./repl.bin" \
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
    if grep -qF "koru-real-elf" "$WORK/repl.serial" && grep -qF "hostexec /usr/bin/busybox status=0" "$WORK/repl.serial"; then
        ok "repl-hostexec: real host ELF ran by path (busybox echo, status=0)"
    else
        bad "repl-hostexec: host child did not run: $(grep -E 'hostexec|koru-real' "$WORK/repl.serial" | tail -3 | tr '\n' '|')"
    fi
    if grep -qF "hostexec /usr/bin/false status=1" "$WORK/repl.serial"; then
        ok "repl-hostexec: child exit status propagates through the seam (false=1)"
    else
        bad "repl-hostexec: exit status lost: $(grep -E 'hostexec' "$WORK/repl.serial" | tail -3 | tr '\n' '|')"
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
sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koruos/hosted/tests/repl-x11.kz" > "$WORK/repl-x11.kz"
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
    sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koruos/hosted/tests/painter.kz" > "$WORK/painter.kz"
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

# --- hosted/wayland — koruos/surface over libwayland-client -------------
# The second hosted surface arm: same fixtures as linux-x11 (repl-x11.kz,
# painter.kz — the iface is provider-agnostic), shim=linux-wayland —
# musl-static with libwayland-client 1.26.0 vendored as source
# (koruos/hosted/wayland/src/) + a musl libffi.a. Zero runtime deps; runs
# on the host AND inside the vroot unchanged. The protocol Hyprland
# speaks — this arm is unchanged when a dmabuf compositor appears.
# Evidence is wire-level (WAYLAND_DEBUG): wayland gives no cross-client
# snooping like xwininfo — the attach+damage+commit stream IS the
# composite by protocol.
sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koruos/hosted/tests/repl-x11.kz" > "$WORK/repl-wl.kz"
bash "$ROOT/scripts/build-hosted.sh" "$WORK/repl-wl.kz" "$WORK/repl-wl.bin" linux-wayland > "$WORK/repl-wl.build" 2>&1 \
    && [ -s "$WORK/repl-wl.bin" ] \
    && ok "surface-wayland: linux-wayland arm builds (musl static + vendored libwayland/libffi)" \
    || { bad "surface-wayland: build failed"; tail -8 "$WORK/repl-wl.build"; }

WLOK=0
MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
    "test -S \"\${XDG_RUNTIME_DIR:-/run/user/0}/wayland-0\"" && WLOK=1
if [ "$WLOK" -eq 1 ]; then
    ok "surface-wayland: live wayland socket wayland-0 (WSLg)"
else
    bad "surface-wayland: no wayland-0 socket — the hosted wayland oracle needs a compositor"
fi

if [ "$WLOK" -eq 1 ] && [ -s "$WORK/repl-wl.bin" ]; then
    MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
        "cd '$WORKWSL' && printf 'surf(width: 640, height: 480) | ok o |> bind(name: \"s\", value: o.surface)\nfill(surface: s, x: 0, y: 0, w: 640, h: 480, color: 16711680)\npresent(surface: s, x: 0, y: 0, w: 640, h: 480)\npresent(surface: s, x: 0, y: 0, w: 0, h: 0)\nsclose(surface: s)\npresent(surface: s, x: 0, y: 0, w: 10, h: 10)\nquit()\n' | WAYLAND_DEBUG=1 KORU_BLK0='$IMGWSL' KORU_NID_STORE='./nid.store' ./repl-wl.bin > '$WORKWSL/wl-sess.log' 2> '$WORKWSL/wl-wire.log'"
    if grep -qF '"value":"s"' "$WORK/wl-sess.log"; then
        ok "surface-wayland: surf() minted *Surf<open!> into the bridge pool (bound 's')"
    else
        bad "surface-wayland: open/bind failed: $(grep -m1 'koru>' "$WORK/wl-sess.log")"
    fi
    W_OKS=$(grep -cF 'unhandled-branch: ok' "$WORK/wl-sess.log")
    if [ "$W_OKS" -ge 3 ] \
       && grep -qF "names nothing the session holds" "$WORK/wl-sess.log" \
       && grep -qF "unhandled-branch: refused" "$WORK/wl-sess.log"; then
        ok "surface-wayland: fill/present/sclose through the pool; empty damage + stale token refuse"
    else
        bad "surface-wayland: borrow path broke: $(grep -E 'error|refused' "$WORK/wl-sess.log" | head -3 | tr '\n' '|')"
    fi
    # wire evidence: real xdg toplevel handshake (configure → ack) and a
    # presented frame (attach + damage_buffer + commit on a 640x480 rect)
    if grep -qE "xdg_surface.*\.configure" "$WORK/wl-wire.log" \
       && grep -qF "ack_configure" "$WORK/wl-wire.log" \
       && grep -qE "wl_surface.*\.attach" "$WORK/wl-wire.log" \
       && grep -qF "damage_buffer(0, 0, 640, 480)" "$WORK/wl-wire.log"; then
        ok "surface-wayland: xdg toplevel configured+mapped, damaged frame committed on the wire"
    else
        bad "surface-wayland: handshake/present wire evidence missing: $(tail -5 "$WORK/wl-wire.log" | tr '\n' '|')"
    fi

    # Session B: open+quit — bridge discharges the held surface through
    # the real provider verb.
    MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
        "cd '$WORKWSL' && printf 'surf(width: 320, height: 240)\nquit()\n' | KORU_BLK0='$IMGWSL' KORU_NID_STORE='./nid.store' ./repl-wl.bin" \
        > "$WORK/wl-sessB.log" 2>&1
    if grep -qE "\[BRIDGE\] Invoked 'sclose' for handle 'h:Surf:[0-9a-f]+'" "$WORK/wl-sessB.log"; then
        ok "surface-wayland: bridge close discharges held surface via provider"
    else
        bad "surface-wayland: unclosed surface not discharged: $(tail -4 "$WORK/wl-sessB.log" | tr '\n' '|')"
    fi

    # painter — the koru-written compositor fixture over wayland: same
    # source as the x11 arm; evidence is the damage stream on the wire
    # (per-rect damage, not full-surface re-pushes).
    sed "s|{{ ENTRY }}|$FIX|g" "$ROOT/koruos/hosted/tests/painter.kz" > "$WORK/painter-wl.kz"
    if bash "$ROOT/scripts/build-hosted.sh" "$WORK/painter-wl.kz" "$WORK/painter-wl.bin" linux-wayland > "$WORK/painter-wl.build" 2>&1; then
        MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
            "cd '$WORKWSL' && WAYLAND_DEBUG=1 timeout 8 ./painter-wl.bin > '$WORKWSL/painter-wl.log' 2> '$WORKWSL/painter-wl-wire.log'"
        if grep -qE "wl_surface.*\.attach" "$WORK/painter-wl-wire.log" \
           && grep -cF "damage_buffer" "$WORK/painter-wl-wire.log" | grep -qE "^[2-9]|[0-9]{2}" \
           && grep -qE "damage_buffer\(120, 100, 40, 40\)" "$WORK/painter-wl-wire.log"; then
            ok "painter-wayland: koru compositor presented per-rect damage to a real compositor"
        else
            bad "painter-wayland: wire evidence missing: $(tail -4 "$WORK/painter-wl-wire.log" | tr '\n' '|')"
        fi
    else
        bad "painter-wayland: build failed"; tail -6 "$WORK/painter-wl.build"
    fi
fi

# --- rig/vroot — vendored rootfs arm ----------------------------------
# The hosted desktop path needs real GUI programs (terminal, compositor,
# webview) that this host's Ubuntu-20.04 cannot package. rig/vroot is
# an Arch rootfs (hyprland/foot/weston/webkit2gtk) entered through
# unshare+chroot with a socket relay for WSLg — same kernel, jail views.
# It is environment state (~/kvroot), not a build artifact: absent is a
# failure, not a skip — same rule as the X server above. Rebuild with
# scripts/mk-vroot.sh.
VROOTSRC_WSL="$(MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e wslpath -u "$(cygpath -w "$ROOT/rig/vroot")" 2>/dev/null)"
KVOK=0
MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
    "test -x ~/kvroot/usr/bin/foot -a -x ~/kvroot/usr/bin/weston -a -x ~/kvroot/usr/bin/Hyprland -a -x ~/kvroot/usr/local/bin/kvview" && KVOK=1
if [ "$KVOK" -eq 1 ] && [ -n "$VROOTSRC_WSL" ]; then
    ok "vroot: vendored rootfs present (foot/weston/hyprland/kvview)"
else
    bad "vroot: ~/kvroot missing or incomplete — run scripts/mk-vroot.sh"
fi

if [ "$KVOK" -eq 1 ]; then
    VRUN="KVROOT_DIR=\$HOME/kvroot bash '$VROOTSRC_WSL/kvroot-run.sh'"
    MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
        "$VRUN foot --version" > "$WORK/vroot-foot.out" 2>&1
    if grep -qF "foot version:" "$WORK/vroot-foot.out"; then
        ok "vroot: userns jail enters + runs vendored binaries (foot --version)"
    else
        bad "vroot: jail entry failed: $(tail -3 "$WORK/vroot-foot.out" | tr '\n' '|')"
    fi

    # Real wayland terminal: foot negotiates WSLg's compositor through
    # the SCM_RIGHTS relay — the "no compositor" error is the failure
    # signal; the optional-protocol warnings are the handshake evidence.
    MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
        "$VRUN timeout 10 foot /bin/sleep 6" > "$WORK/vroot-term.out" 2>&1
    if grep -qF "compositor does not implement" "$WORK/vroot-term.out" \
       && ! grep -qF "failed to connect to wayland" "$WORK/vroot-term.out"; then
        ok "vroot-term: real wayland terminal (foot) negotiated WSLg through the relay"
    else
        bad "vroot-term: wayland handshake failed: $(tail -3 "$WORK/vroot-term.out" | tr '\n' '|')"
    fi

    # Nested compositor: weston serves wayland-1 on WSLg's wayland
    # backend (wl_shm — no dmabuf needed), and foot is its client.
    # Two levels of real compositing on the hosted arm.
    MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
        "$VRUN nest-weston" > "$WORK/vroot-nest.out" 2>&1
    if grep -qF "VROOT-NESTED-SOCKET" "$WORK/vroot-nest.out" \
       && [ "$(tail -1 "$WORK/vroot-nest.out")" = "0" ]; then
        ok "vroot-compositor: nested weston served foot on wayland-1 (2-level compositing)"
    else
        bad "vroot-compositor: nested compositor failed: $(tail -3 "$WORK/vroot-nest.out" | tr '\n' '|')"
    fi

    # Vendored webview: webkit2gtk through the relay, page loaded and
    # DOM evaluated — the "unlocks most programs" rung.
    MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
        "$VRUN timeout 15 env WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 kvview file:///tmp/kvtest.html" \
        > "$WORK/vroot-web.out" 2>&1
    if grep -qF 'KVVIEW loaded title="KVTEST-OK"' "$WORK/vroot-web.out"; then
        ok "vroot-webview: vendored webkit rendered a page (DOM title read back)"
    else
        bad "vroot-webview: webview evidence missing: $(tail -3 "$WORK/vroot-web.out" | tr '\n' '|')"
    fi

    # hostexec reaches the jail: the same seam that ran busybox now runs
    # vendored programs — jail entry is a program, not a seam change.
    MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
        "cd '$WORKWSL' && printf 'hostexec(path: \"$VROOTSRC_WSL/kvroot-run.sh\", args: \"foot --version\", rights: 3)\nquit()\n' | KORU_BLK0='$IMGWSL' KORU_NID_STORE='./nid.store' ./repl.bin" \
        > "$WORK/vroot-seam.log" 2>&1
    if grep -qF "foot version:" "$WORK/vroot-seam.log" \
       && grep -qF "kvroot-run.sh status=0" "$WORK/vroot-seam.log"; then
        ok "vroot-seam: hostexec spawns vendored binaries through the jail"
    else
        bad "vroot-seam: hostexec+ jail failed: $(grep -E 'hostexec|foot' "$WORK/vroot-seam.log" | tail -3 | tr '\n' '|')"
    fi

    # Measured refusal oracle: hyprland refuses on this compositor —
    # aquamarine's wayland backend demands zwp_linux_dmabuf_v1, which
    # WSLg (software, no /dev/dri) does not advertise. This row pins the
    # refusal reason; if it ever flips the ENVIRONMENT changed, not the code.
    MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
        "$VRUN timeout 10 env HOME=/root Hyprland --i-am-really-stupid" \
        > "$WORK/vroot-hypr.out" 2>&1
    if grep -qE "Missing protocols|no allocator available" "$WORK/vroot-hypr.out"; then
        ok "vroot-hyprland: honest refusal — needs dmabuf/DRM seat WSLg lacks"
    else
        bad "vroot-hyprland: unexpected outcome (env changed?): $(tail -3 "$WORK/vroot-hypr.out" | tr '\n' '|')"
    fi

    # Live Hyprland oracle: kv-shim (dmabuf-v4 parent) -> aquamarine GBM
    # on vgem card0 -> real Hyprland -> foot + Quickshell layer-bar +
    # Noctalia layers (when the build-release is staged). vgem is host
    # kernel state the gate can provision (passwordless root on WSL);
    # a failed modprobe reports the environment honestly, never fakes.
    REPWSL="$(MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e wslpath -u "$(cygpath -w "$ROOT")" 2>/dev/null)"
    MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e test -e /dev/dri/card0 \
        || MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -u root -e modprobe vgem > /dev/null 2>&1 \
        || true
    if ! MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e test -e /dev/dri/card0; then
        bad "vroot-hypr-oracle: no /dev/dri/card0 and vgem would not load (host kernel state)"
    else
        # stage the koru linux-wayland surface client — the second host
        # realization path runs it against Hyprland's own socket.
        if [ -s "$WORK/repl-wl.bin" ]; then
            MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
                "mkdir -p ~/kvroot/opt/kv && cp '$WORKWSL/repl-wl.bin' ~/kvroot/opt/kv/repl-wl.bin" \
                > /dev/null 2>&1 || true
        fi
        MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
            "cd '$REPWSL' && timeout 240 bash rig/vroot/hypr-oracle.sh" \
            > "$WORK/hypr-oracle.out" 2>&1
        if grep -qF "ORACLE-PASS" "$WORK/hypr-oracle.out" \
           && grep -qF "QS-UP" "$WORK/hypr-oracle.out"; then
            stages="foot+quickshell"
            grep -qF "NOC-UP" "$WORK/hypr-oracle.out" && stages="$stages+noctalia"
            grep -qF "KORU-SURF-UP" "$WORK/hypr-oracle.out" && stages="$stages+koru-surface"
            ok "vroot-hypr-oracle: $stages — real dmabuf commits + pixel evidence ($(grep -oE 'nonbg=[0-9]+' "$WORK/hypr-oracle.out" | tail -1))"
        else
            bad "vroot-hypr-oracle: $(grep -aE 'ORACLE-FAIL|NOC-FAIL|PXEVID' "$WORK/hypr-oracle.out" | tail -3 | tr '\n' '|')"
        fi
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
