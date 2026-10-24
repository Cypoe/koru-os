#!/bin/bash
# vroot-enter: enter the vendored rootfs ($KVROOT_DIR) — run inside
# `unshare -Urmpf` (userns+mount+pid+fork). WSL2 refuses bind-mounts of
# foreign tmpfs mounts (/mnt/wslg, /dev) and mknod outright, so:
#   - wayland/X11/pulse sockets arrive via the host-side relay into
#     $R/mnt/wslg/... and $R/tmp/.X11-unix/... (real files on ext4),
#   - /dev is a fresh userns-owned tmpfs + devpts; null/full are
#     symlinks to an empty file (open/read-EOF/write-discard — the
#     common /dev/null semantics), and random/urandom/zero are fifos
#     the relay feeds (entropy and zeros must not EOF — a program that
#     reads /dev/urandom and gets 0 bytes spins forever; measured).
R=${KVROOT_DIR:-$HOME/kvroot}
mkdir -p "$R"/{mnt/wslg/runtime-dir/pulse,tmp/.X11-unix,run,dev/pts,dev/shm,proc,sys,etc}
mount -t tmpfs tmpfs "$R/dev"      2>/dev/null
mkdir -p "$R/dev/pts" "$R/dev/shm"
mount -t devpts devpts "$R/dev/pts" -o ptmxmode=666,mode=620 2>/dev/null
mount -t tmpfs tmpfs "$R/dev/shm"  -o mode=1777
mount -t tmpfs tmpfs "$R/run"      -o mode=1777
mount -t proc   proc   "$R/proc"   2>/dev/null
mount -t tmpfs tmpfs "$R/sys"      2>/dev/null
ln -sf pts/ptmx "$R/dev/ptmx"
: > "$R/tmp/kvnull"; chmod 666 "$R/tmp/kvnull"
for n in null full; do ln -sf /tmp/kvnull "$R/dev/$n"; done
ln -sf /tmp/kvfifo-urandom "$R/dev/urandom"
ln -sf /tmp/kvfifo-random  "$R/dev/random"
ln -sf /tmp/kvfifo-zero    "$R/dev/zero"
cp -L /etc/resolv.conf "$R/etc/resolv.conf" 2>/dev/null
cp -L /etc/hosts "$R/etc/hosts" 2>/dev/null
exec chroot "$R" env -i \
  HOME=/root PATH=/usr/local/bin:/usr/bin:/bin DISPLAY=:0 \
  XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir \
  WAYLAND_DISPLAY=wayland-0 DBUS_SESSION_BUS_ADDRESS= \
  "$@"
