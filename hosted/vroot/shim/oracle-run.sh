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
print(f"PXEVID {w}x{h} nonbg={nonbg} magenta={mag}")
assert nonbg > 1000, "frame essentially black"
assert mag > 100, "no magenta border evidence"
PY
[ $? -eq 0 ] || fail "pixel evidence"

echo "ORACLE-PASS"
kill $HYPRPID $SHIMPID 2>/dev/null
exit 0
