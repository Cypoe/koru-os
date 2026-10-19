#!/usr/bin/env bash
# M9 inputs: Debian forky (testing) packages for Hyprland + foot and their closure, through a
# private apt configuration (signature-checked with the box's Debian archive keyring), no root.
# Excluded from the Depends closure (not needed to run the compositor): systemd, dbus, polkitd,
# python, perl, binutils. Nothing fetched here is committed.
# Usage: fetch.sh <aptdir> <outdir>   -> <outdir>/deb/*.deb, <outdir>/stage (extracted)
set -eu
A=$1; O=$2
mkdir -p "$A"/{lists/partial,cache/archives/partial,etc/apt.conf.d,etc/preferences.d,etc/sources.list.d} "$O/deb"
echo 'deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] http://deb.debian.org/debian forky main' > "$A/etc/sources.list"
cat > "$A/apt.conf" <<C
Dir::Etc "$A/etc"; Dir::State "$A/"; Dir::State::Lists "$A/lists"; Dir::State::status "$A/status";
Dir::Cache "$A/cache"; APT::Architecture "amd64"; Acquire::Languages "none"; Debug::NoLocking "true";
C
touch "$A/status"; export APT_CONFIG=$A/apt.conf
apt-get update -q
apt-get -s -o APT::Install-Recommends=false install hyprland foot seatd libseat1 fontconfig \
  fonts-dejavu-core xkb-data libgl1-mesa-dri libegl-mesa0 libgles2 libgbm1 wayland-utils libinput-tools \
  | awk '/^Inst/ {print $2}' \
  | grep -Ev '^(systemd|systemd-sysv|libsystemd-shared|python3.*|libpython3.*|perl.*|libperl.*|dbus.*|libpam-systemd|polkitd|binutils.*|libbinutils|libctf.*|libgprofng.*|libsframe.*|libjansson4|gcc-.*-base)$' > "$O/dl.txt"
(cd "$O/deb" && apt-get download $(cat "$O/dl.txt"))
rm -rf "$O/stage"; mkdir "$O/stage"; for d in "$O"/deb/*.deb; do dpkg-deb -x "$d" "$O/stage"; done
