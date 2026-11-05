#!/bin/bash
# build-shim — compile kv-shim inside the jail (gcc + wayland-server are
# vendored; protocol code is generated from the vendored XMLs so the shim
# can never drift from the rootfs's protocol definitions).
set -e
B=/opt/kv/shim-build
mkdir -p $B
W=/usr/share/wayland-protocols
wayland-scanner server-header $W/stable/xdg-shell/xdg-shell.xml \
    $B/xdg-shell-server-protocol.h
wayland-scanner private-code  $W/stable/xdg-shell/xdg-shell.xml \
    $B/xdg-shell-protocol.c
wayland-scanner server-header $W/stable/linux-dmabuf/linux-dmabuf-v1.xml \
    $B/linux-dmabuf-v1-server-protocol.h
wayland-scanner private-code  $W/stable/linux-dmabuf/linux-dmabuf-v1.xml \
    $B/linux-dmabuf-v1-protocol.c
gcc -O2 -Wall -I$B -o $B/kv-shim /opt/kv/kv-shim.c \
    $B/xdg-shell-protocol.c $B/linux-dmabuf-v1-protocol.c \
    $(pkg-config --cflags --libs wayland-server)
echo "SHIM-BUILD-OK"
