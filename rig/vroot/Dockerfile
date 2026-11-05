# kvroot — the vendored userspace rootfs for the hosted desktop path.
# Arch carries what Ubuntu-20.04 (the host WSL) cannot: hyprland, foot,
# weston, webkit2gtk-4.1. Built by scripts/mk-vroot.sh; entered through
# vroot-enter.sh inside `unshare -Urmpf` — no root, no daemon-side mount
# bridging. /mnt/wslg is a foreign tmpfs (binds refused); sockets ride
# vroot-relay.py instead.
FROM archlinux:latest
RUN pacman -Syu --noconfirm --needed \
    hyprland foot weston xterm \
    webkit2gtk-4.1 gtk3 \
    wayland-protocols libxkbcommon \
    ttf-dejavu socat gcc make pkgconf dbus seatd mesa \
    strace gdb \
 && pacman -Scc --noconfirm \
 && echo DisableSandbox >> /etc/pacman.conf
# in-jail package installs need pacman's download sandbox off: the
# sandbox user is unmapped inside the user namespace.
COPY kvview.c /tmp/kvview.c
COPY kvtest.html /tmp/kvtest.html
COPY hyprland.conf /root/.config/hypr/hyprland.conf
COPY nest-weston.sh /usr/local/bin/nest-weston
RUN chmod +x /usr/local/bin/nest-weston \
 && gcc -O2 -o /usr/local/bin/kvview /tmp/kvview.c \
    $(pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.1)
