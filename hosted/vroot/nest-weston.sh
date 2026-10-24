#!/bin/bash
# nest-weston — nested compositor smoke: weston serves wayland-1 on
# WSLg's wayland backend (wl_shm), then a foot client attaches. Run
# inside the jail. Prints VROOT-NESTED-SOCKET + the foot connect-fail
# count — the gate reads both.
weston --backend=wayland --socket=wayland-1 --renderer=pixman \
    --width=800 --height=600 > /tmp/nw.log 2>&1 &
WPID=$!
for i in $(seq 40); do [ -S /mnt/wslg/runtime-dir/wayland-1 ] && break; sleep 0.25; done
[ -S /mnt/wslg/runtime-dir/wayland-1 ] && echo VROOT-NESTED-SOCKET
sleep 1
WAYLAND_DISPLAY=wayland-1 timeout 6 foot /bin/sleep 4 > /tmp/nf.out 2>&1
grep -c 'failed to connect' /tmp/nf.out
kill $WPID 2>/dev/null
