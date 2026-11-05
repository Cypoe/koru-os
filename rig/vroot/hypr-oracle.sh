#!/bin/bash
# hypr-oracle — host-side driver for the vroot Hyprland oracle.
# Stages shim/ + scripts into the rootfs at /opt/kv (bind-visible to the
# jail), then runs oracle-run.sh via kvroot-run. The kernel-side device
# half (vgem module + /dev/dri bind) is vroot-enter.sh's job; if /dev/dri
# is missing the oracle says so rather than faking success.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
R=${KVROOT_DIR:-$HOME/kvroot}

mkdir -p "$R/opt/kv" "$R/opt/kv/qs-oracle"
cp "$HERE"/shim/kv-shim.c "$HERE"/shim/build-shim.sh \
   "$HERE"/shim/fake-sysfs-dri.sh "$HERE"/shim/oracle-run.sh \
   "$HERE"/shim/hyprland-oracle.conf "$R/opt/kv/"
cp "$HERE"/shim/qs-oracle/shell.qml "$R/opt/kv/qs-oracle/"
chmod +x "$R/opt/kv"/*.sh

if [ ! -e /dev/dri/card0 ]; then
    echo "ORACLE-FAIL no /dev/dri — load vgem as WSL root: wsl -u root modprobe vgem"
    exit 1
fi

exec bash "$HERE/kvroot-run.sh" bash /opt/kv/${KV_ORACLE_SCRIPT:-oracle-run.sh}
