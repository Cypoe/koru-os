#!/usr/bin/env bash
# M9 userland tree: Debian forky (testing) binaries and their library closure, resolved with
# forky's own ld.so, plus the data they load at run time. Nothing here is committed; the
# package list is fetch.sh's. Usage: mkroot.sh <forky stage> <libudev-zero .so> <dst>
# Layout: /lib64/ld-linux-x86-64.so.2, /lib/x86_64-linux-gnu (all libraries, glibc 2.43),
# /usr/lib/x86_64-linux-gnu -> ../../lib/x86_64-linux-gnu, /usr/bin, /usr/share, /etc/fonts.
set -eu
S=$1; UDZ=$2; D=$3; L=$S/usr/lib/x86_64-linux-gnu
BINS="usr/bin/Hyprland usr/bin/hyprctl usr/bin/foot usr/bin/footclient usr/bin/fc-match usr/bin/fc-list
 usr/bin/fc-cache usr/bin/wayland-info usr/sbin/seatd usr/bin/seatd-launch usr/bin/libinput"
DLOPEN="libEGL_mesa.so.0 libgallium-*.so libgbm.so.1 gbm/dri_gbm.so libEGL.so.1 libGLESv2.so.2 libGL.so.1
 libGLX_mesa.so.0 libinput.so.10 libseat.so.1 libxkbcommon.so.0 libdrm.so.2 libwayland-egl.so.1"
mkdir -p "$D"/{lib64,lib/x86_64-linux-gnu,usr/bin,usr/sbin,usr/libexec,usr/share,usr/lib,etc}
ln -sfn ../../lib/x86_64-linux-gnu "$D/usr/lib/x86_64-linux-gnu"
cp -L "$S/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" "$D/lib64/"
for b in $BINS; do [ -e "$S/$b" ] && cp -L "$S/$b" "$D/$b"; done
cp -r "$S/usr/libexec/libinput" "$D/usr/libexec/" 2>/dev/null || true
list() { "$S/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2" --library-path "$L" --list "$1" 2>/dev/null | awk '$3 ~ /^\// {print $3}'; }
{ for b in $BINS usr/libexec/libinput/*; do [ -e "$S/$b" ] && list "$S/$b"; done
  for p in $DLOPEN; do for f in $L/$p; do [ -e "$f" ] && { echo "$f"; list "$f"; }; done; done; } | sort -u > "$D/.libs"
while read -r l; do r=${l#$L/}; mkdir -p "$D/lib/x86_64-linux-gnu/$(dirname "$r")"; cp -L "$l" "$D/lib/x86_64-linux-gnu/$r"; done < "$D/.libs"
cp -L "$L"/dri/kms_swrast_dri.so "$L"/dri/swrast_dri.so "$D/lib/x86_64-linux-gnu/" 2>/dev/null || true
mkdir -p "$D/lib/x86_64-linux-gnu/dri"; for f in "$L"/dri/{kms_swrast,swrast}_dri.so; do [ -e "$f" ] && cp -L "$f" "$D/lib/x86_64-linux-gnu/dri/"; done
cp "$UDZ" "$D/lib/x86_64-linux-gnu/libudev.so.1"
for s in fonts fontconfig xkeyboard-config-2 X11 libinput hypr glvnd wayland-sessions icons/default; do [ -e "$S/usr/share/$s" ] && cp -a "$S/usr/share/$s" "$D/usr/share/" ; done
cp -a "$S/etc/fonts" "$D/etc/"; cp "$(dirname "$0")/hyprland.lua" "$D/etc/m9-hyprland.lua"; [ -d "$S/etc/glvnd" ] && cp -a "$S/etc/glvnd" "$D/etc/"
mkdir -p "$D/usr/lib/locale"; cp -a "$S/usr/lib/locale/C.utf8" "$D/usr/lib/locale/" # foot needs a UTF-8 locale (libc-bin)
rm -f "$D/.libs"; du -sh "$D"
