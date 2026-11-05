#!/bin/bash
# oracle-run — the vroot Hyprland oracle, executed INSIDE the jail.
# Chain: fake sysfs -> kv-shim (dmabuf-v4 parent on vgem card0) ->
# real Hyprland (aquamarine wayland backend + GBM/vgem allocator) ->
# foot (exec-once). Evidence lands in /tmp/{shim,hypr,foot}.log and
# /tmp/kv-frame.ppm (shim readback of Hyprland's committed dmabuf).
set -u
KO=/opt/kv
export XDG_RUNTIME_DIR=/run/kv
mkdir -p $XDG_RUNTIME_DIR; chmod 700 $XDG_RUNTIME_DIR
export HOME=/root

fail() { echo "ORACLE-FAIL $*"; exit 1; }

$KO/fake-sysfs-dri.sh card0 || fail "fake sysfs"
$KO/build-shim.sh || fail "shim build"

SHIM_SOCK=kv-shim SHIM_DRM_NODE=/dev/dri/card0 \
  SHIM_DUMP=/tmp/kv-frame.ppm SHIM_DUMP_EVERY=1 \
  $KO/shim-build/kv-shim 2>/tmp/shim.log &
SHIMPID=$!
for i in $(seq 1 30); do [ -S $XDG_RUNTIME_DIR/kv-shim ] && break; sleep 0.3; done
grep -q "SHIM READY" /tmp/shim.log || fail "shim socket"
echo "SHIM-UP"

WAYLAND_DISPLAY=kv-shim AQ_TRACE=1 AQ_DEBUG=1 Hyprland --i-am-really-stupid \
    --config $KO/hyprland-oracle.conf > /tmp/hypr.log 2>&1 &
HYPRPID=$!

# bounded wait for output init OR a named refusal
for i in $(seq 1 80); do
    grep -q "Output WAYLAND-1" /tmp/hypr.log && grep -qiE "init|layout" /tmp/hypr.log && break
    grep -qiE "no allocator|cannot open backend|dumped core|segfault|fatal" /tmp/hypr.log && break
    kill -0 $HYPRPID 2>/dev/null || break
    sleep 0.5
done

echo "== aq/backend =="
grep -inE "aquamarine|allocator|wayland|drm|Output|backend|error|critical" /tmp/hypr.log | head -40

if ! kill -0 $HYPRPID 2>/dev/null; then fail "hyprland exited"; fi

# let Hyprland+foot settle and render
sleep 8

echo "== shim commits =="
grep -E "SHIM (SURFACE|COMMIT|TOPLEVEL|XDG|FEEDBACK|DUMP)" /tmp/shim.log | tail -30

grep -q "SHIM COMMIT" /tmp/shim.log || fail "no dmabuf commits"
grep -q "SHIM XDG-ACK" /tmp/shim.log || echo "note: no xdg ack (aq defers acks; commits flow anyway)"
grep -qiE "Running on|Hyprland.*ready|New XDG Surface|wayland-[0-9]" /tmp/hypr.log || true

# foot evidence: Hyprland's own socket + a toplevel in hyprctl
HYPR_SOCK=$(ls $XDG_RUNTIME_DIR/hypr/*/.socket.sock 2>/dev/null | head -1)
[ -n "$HYPR_SOCK" ] || fail "no hyprland instance socket"
HYPRLAND_INSTANCE_SIGNATURE=$(basename $(dirname $HYPR_SOCK)) \
  hyprctl clients > /tmp/clients.txt 2>&1 || true
echo "== clients =="; cat /tmp/clients.txt
grep -qiE "foot" /tmp/clients.txt || fail "foot not in hyprctl clients"
echo "FOOT-CLIENT"

# Quickshell stage: real layer-shell surface on the live Hyprland.
# Software QML backend — deterministic wl_shm pixels, no EGL dependency.
WAYLAND_DISPLAY=wayland-1 QT_QPA_PLATFORM=wayland QT_QUICK_BACKEND=software \
  QT_WAYLAND_DISABLE_WINDOWDECORATION=1 \
  qs -p /opt/kv/qs-oracle/shell.qml >/tmp/qs.log 2>&1 &
QSPID=$!
sleep 5
kill -0 $QSPID 2>/dev/null || { tail -15 /tmp/qs.log; fail "quickshell exited"; }
grep -qiE "shell|error|fatal" /tmp/qs.log && tail -8 /tmp/qs.log || true
echo "QS-UP"

[ -f /tmp/kv-frame.ppm ] || fail "no frame dump"
head -2 /tmp/kv-frame.ppm
python3 - <<'PY'
import sys
d = open('/tmp/kv-frame.ppm','rb').read()
# parse P6
tok = d.split(b'\n',3)
w,h = map(int, tok[1].split())
px = tok[3]
nonbg = sum(1 for i in range(0,len(px)-3,3) if px[i] or px[i+1] or px[i+2])
# magenta border evidence (ff00ff)
mag = sum(1 for i in range(0,len(px)-3,3) if px[i]>200 and px[i+1]<60 and px[i+2]>200)
# cyan layer-shell bar (00ffff) — 40px band across the top
cyan = sum(1 for i in range(0,len(px)-3,3) if px[i]<60 and px[i+1]>200 and px[i+2]>200)
print(f"PXEVID {w}x{h} nonbg={nonbg} magenta={mag} cyan={cyan}")
assert nonbg > 1000, "frame essentially black"
assert mag > 100, "no magenta border evidence"
assert cyan > 20000, "no quickshell layer-bar evidence"
PY
[ $? -eq 0 ] || fail "pixel evidence"

# noctalia stage: the real shell daemon — C++/QtQuick layer-shell
# surfaces under the live Hyprland. The binary lands at /opt/kv/noctalia
# from a build-release tree staged into the rootfs; absent = honest
# skip, never a faked pass.
NOCBIN=/opt/kv/noctalia/build-release/noctalia
if [ -x "$NOCBIN" ]; then
    WAYLAND_DISPLAY=wayland-1 QT_QPA_PLATFORM=wayland \
      XDG_CONFIG_HOME=/root/.config XDG_DATA_HOME=/root/.local/share \
      "$NOCBIN" >/tmp/noc.log 2>&1 &
    NOCPID=$!
    sleep 10
    if ! kill -0 $NOCPID 2>/dev/null; then
        tail -25 /tmp/noc.log
        fail "noctalia exited"
    fi
    HYPRLAND_INSTANCE_SIGNATURE=$(basename $(dirname $HYPR_SOCK)) \
      hyprctl layers > /tmp/layers.txt 2>&1 || true
    grep -q "noctalia-bar" /tmp/layers.txt || { cat /tmp/layers.txt; fail "no noctalia bar layer"; }
    grep -q "noctalia-wallpaper" /tmp/layers.txt || { cat /tmp/layers.txt; fail "no noctalia wallpaper layer"; }
    sleep 3
    python3 - <<'PY'
d = open('/tmp/kv-frame.ppm','rb').read()
tok = d.split(b'\n',3)
w,h = map(int, tok[1].split())
px = tok[3]
nonbg = sum(1 for i in range(0,len(px)-3,3) if px[i] or px[i+1] or px[i+2])
print(f"NOC-PXEVID {w}x{h} nonbg={nonbg}")
assert nonbg > 500000, "noctalia wallpaper did not cover the frame"
PY
    [ $? -eq 0 ] || fail "noctalia pixel evidence"
    echo "NOC-UP"
    kill $NOCPID 2>/dev/null
else
    echo "NOC-SKIP no /opt/kv/noctalia binary — build-release not staged"
fi

# second host realization path: the koru linux-wayland surface provider
# — a musl-static binary with zero deps — runs inside the jail and
# connects to THIS Hyprland (wayland-1), so surf/fill/present are
# realized by the real compositor, not WSLg. Staged by check-hosted.
if [ -x /opt/kv/repl-wl.bin ]; then
    dd if=/dev/zero of=/tmp/blk0.img bs=1M count=8 2>/dev/null
    mke2fs -q -F -t ext2 -b 1024 -I 128 /tmp/blk0.img 8192 >/dev/null 2>&1
    { printf 'surf(width: 320, height: 240) | ok o |> bind(name: "s", value: o.surface)\n'
      printf 'fill(surface: s, x: 0, y: 0, w: 320, h: 240, color: 16711680)\n'
      printf 'present(surface: s, x: 0, y: 0, w: 320, h: 240)\n'
      sleep 8
      printf 'quit()\n'; } | \
      WAYLAND_DISPLAY=wayland-1 KORU_BLK0=/tmp/blk0.img KORU_NID_STORE=/tmp/nid.store \
      /opt/kv/repl-wl.bin >/tmp/koru-surf.log 2>&1 &
    SURFPID=$!
    sleep 5
    HYPRLAND_INSTANCE_SIGNATURE=$(basename $(dirname $HYPR_SOCK)) \
      hyprctl clients > /tmp/clients2.txt 2>&1 || true
    grep -q "koru-os" /tmp/clients2.txt || {
        cat /tmp/clients2.txt; tail -10 /tmp/koru-surf.log
        fail "koru surface not in hyprctl clients"; }
    sleep 3
    python3 - <<'PY'
d = open('/tmp/kv-frame.ppm','rb').read()
tok = d.split(b'\n',3)
w,h = map(int, tok[1].split())
px = tok[3]
red = sum(1 for i in range(0,len(px)-3,3) if px[i]>200 and px[i+1]<60 and px[i+2]<60)
print(f"KORU-SURF-PXEVID {w}x{h} red={red}")
assert red > 30000, "koru surface pixels not composited"
PY
    [ $? -eq 0 ] || fail "koru surface pixel evidence"
    echo "KORU-SURF-UP"
    wait $SURFPID 2>/dev/null || true
else
    echo "KORU-SURF-SKIP no /opt/kv/repl-wl.bin staged"
fi

echo "ORACLE-PASS"
kill $HYPRPID $SHIMPID $QSPID 2>/dev/null
exit 0
