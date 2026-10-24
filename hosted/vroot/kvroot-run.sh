#!/bin/bash
# kvroot-run <cmd...> — run a vendored-rootfs program through the
# userns jail. Restarts the socket/fifo relay when absent, then enters.
# hostexec targets this by host path — the spawn seam hands children an
# EMPTY envp (ambient env is a leak channel; the bag governs), so this
# script resolves its own PATH and home instead of trusting ambient.
export PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -z "$KVROOT_DIR" ]; then
  H="${HOME:-$(getent passwd "$(id -un)" | cut -d: -f6)}"
  KVROOT_DIR="$H/kvroot"
fi
export KVROOT_DIR
if ! pgrep -f "vroot-relay\.py" >/dev/null; then
  nohup python3 -u "$HERE/vroot-relay.py" > /tmp/vroot-relay.log 2>&1 &
  sleep 1
fi
exec unshare -Urmpf "$HERE/vroot-enter.sh" "$@"
