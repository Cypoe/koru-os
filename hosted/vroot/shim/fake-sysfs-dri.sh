#!/bin/bash
# fake-sysfs-dri — synthesize the /sys tree libdrm needs inside the vroot.
#
# drmGetDeviceFromDevId(dev_t) stats /sys/dev/char/<maj>:<min>/device/drm,
# enumerates the node dirs below it, and maps dev_t -> /dev/dri/* paths.
# The jail's /sys is a fresh tmpfs, so we build exactly the tree it wants —
# real dirs/files, no udev. Only the node basenames given in $1 (default
# "card0 renderD128") are advertised under device/drm/, which is how we make
# aquamarine pick the PRIMARY node (card0): a render fd cannot
# DRM_IOCTL_MODE_CREATE_DUMB (DRM_AUTH), a master primary fd can.
# Runs inside the jail, after /dev/dri has been bound in.
set -e
NODES=${1:-card0}
mkdir -p /sys/bus/faux/drivers/vgem
# Only the nodes named in $1 get a /sys/dev/char tree at all — libdrm
# attributes siblings by scanning /dev/dri and resolving each node's sysfs
# device link, so a render node with no tree stays invisible to
# drmGetDeviceFromDevId and available_nodes reports PRIMARY only.
for sb in $NODES; do
    s=/dev/dri/$sb; [ -e $s ] || continue
    smm=$(stat -c %t:%T $s) || continue
    smaj=$((16#${smm%%:*})); smin=$((16#${smm##*:}))
    dev=/sys/dev/char/$smaj:$smin
    mkdir -p $dev/device/drm/$sb
    echo "$smaj:$smin" > $dev/device/drm/$sb/dev
    printf "MAJOR=%s\nMINOR=%s\nDEVNAME=dri/%s\nDEVTYPE=drm_minor\n" \
        $smaj $smin $sb > $dev/device/drm/$sb/uevent
    # drmGetDeviceNameFromFd2 reads DEVNAME off the char path's own uevent
    cp $dev/device/drm/$sb/uevent $dev/uevent
    echo "$smaj:$smin" > $dev/dev
    echo DRIVER=vgem > $dev/device/uevent
    ln -sfn ../../../bus/faux $dev/device/subsystem
    ln -sfn ../../faux/drivers/vgem $dev/device/driver
done
echo "FAKE-SYSFS-OK nodes=[$NODES]"
