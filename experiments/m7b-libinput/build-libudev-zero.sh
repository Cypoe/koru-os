#!/usr/bin/env bash
# libudev-zero (ISC, https://github.com/illiliti/libudev-zero), a daemonless libudev: it
# reads /sys directly (uevent, subsystem links, /sys/dev/char) and derives ID_INPUT_* from
# the input device's EV/KEY/... uevent bitmaps, so no udevd and no /run/udev database.
# Built from a pinned commit with the LIBUDEV_183 symbol version (as the meson build does),
# so unmodified Debian binaries linked against systemd's libudev.so.1 bind to it.
# Usage: build-libudev-zero.sh <workdir>   -> <workdir>/libudev-zero/libudev.so.1
set -eu
REV=8f1d3d0624496f1c4967f18d6afaddbd552d8bce
mkdir -p "$1" && cd "$1"
[ -d libudev-zero ] || git clone -q https://github.com/illiliti/libudev-zero.git
cd libudev-zero && git checkout -q $REV && make clean >/dev/null 2>&1 || true
make -s CFLAGS="-O2 -g0" LDFLAGS="-Wl,--version-script=libudev.sym" libudev.so.1
sha256sum libudev.so.1
