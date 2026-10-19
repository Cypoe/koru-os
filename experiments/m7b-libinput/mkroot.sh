#!/usr/bin/env bash
# M7b userland tree <dst>: Debian libinput 1.28.1 tools (libinput, libinput-debug-events),
# libinput/libevdev/libmtdev/libwacom from <m7bin root>, quirks and libwacom data, glibc and the
# remaining dependencies from the box. With UDEV=<udev root> also systemd-udevd/udevadm 257
# and its rules (L1 oracle only). Usage: [UDEV=dir] mkroot.sh <m7bin root> <dst>
set -eu
IN=$1; D=$2; L=$D/lib/x86_64-linux-gnu
mkdir -p "$D"/{bin,lib64,usr/bin,usr/libexec,usr/share} "$L"
cp "$IN/usr/bin/libinput" "$D/usr/bin/"; cp -r "$IN/usr/libexec/libinput" "$D/usr/libexec/"
cp -r "$IN/usr/share/libinput" "$IN/usr/share/libwacom" "$D/usr/share/"
cp -L /lib64/ld-linux-x86-64.so.2 "$D/lib64/"
export LD_LIBRARY_PATH=$IN/usr/lib/x86_64-linux-gnu
B="$D/usr/bin/libinput $D/usr/libexec/libinput/libinput-debug-events"
if [ -n "${UDEV:-}" ]; then
  mkdir -p "$D/usr/lib/systemd" "$D/usr/lib/udev" "$L/systemd"
  cp "$UDEV/usr/bin/udevadm" "$D/usr/bin/"; ln -sf ../../bin/udevadm "$D/usr/lib/systemd/systemd-udevd"
  cp -r "$UDEV/usr/lib/udev/rules.d" "$D/usr/lib/udev/"; cp -r "$UDEV"/usr/lib/udev/*_id "$D/usr/lib/udev/" 2>/dev/null || true
  cp "$UDEV"/usr/lib/x86_64-linux-gnu/systemd/*.so "$L/systemd/"
  export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$UDEV/usr/lib/x86_64-linux-gnu/systemd
  B="$B $D/usr/bin/udevadm"
fi
for b in $B; do ldd "$b" | awk '$3 ~ /^\// {print $3}'; done | sort -u | while read -r l; do
  case "$l" in */systemd/*) ;; *) cp -L "$l" "$L/";; esac; done
