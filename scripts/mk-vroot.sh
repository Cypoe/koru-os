#!/bin/bash
# mk-vroot — build the vendored rootfs (rig/vroot/Dockerfile →
# docker export → $KVROOT_DIR) and smoke the jail. The rootfs is
# environment state, not a build artifact: it lives in the WSL home,
# not the repo. Run once per host; check-hosted's vroot rows probe for
# it and refuse loudly when absent — a missing oracle is a failure,
# not a skip, same as a missing X server.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
VROOT_SRC="$HERE/../rig/vroot"
KVROOT_DIR="${KVROOT_DIR:-/home/$USER/kvroot}"
WSL_DISTRO="${WSL_DISTRO:-Ubuntu}"

echo "mk-vroot: building kvroot image (docker)..."
docker build -t kvroot -f "$VROOT_SRC/Dockerfile" "$VROOT_SRC"

echo "mk-vroot: exporting rootfs → $KVROOT_DIR (inside $WSL_DISTRO)..."
CID=$(docker create kvroot)
MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
    "mkdir -p '$KVROOT_DIR' && rm -rf '$KVROOT_DIR'/*"
docker export "$CID" | MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e \
    bash -c "tar x -C '$KVROOT_DIR'"
docker rm "$CID" > /dev/null

echo "mk-vroot: smoke — foot --version through the jail"
MSYS2_ARG_CONV_EXCL='*' wsl -d "$WSL_DISTRO" -e bash -c \
    "KVROOT_DIR='$KVROOT_DIR' bash '$(cd "$VROOT_SRC" && wslpath -u "$(cygpath -w "$VROOT_SRC")")/kvroot-run.sh' foot --version" 2>&1 | tail -3 || true
echo "mk-vroot: done — rootfs at $KVROOT_DIR (WSL: $WSL_DISTRO)"
