/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M7b: a minimal Linux sysfs view (/sys, ramfs), written by the kernel.
 * A provider publishes the nodes of its own hardware (bus device and parents);
 * a personality publishes the class device it creates (input0/event0, card0).
 * Nothing here knows which provider is behind a row: a native driver and a
 * driver silo publish the same way (DESIGN-0001 Q28 stays open).
 * Paths are relative to /sys. Calls before /sys is mounted are queued and
 * replayed by the late initcall that mounts it.
 */
#ifndef KORU_SYSFS_H
#define KORU_SYSFS_H

/* mkdir -p /sys/<path> */
int korusysfs_dir(const char *path);
/* /sys/<path> := content (parents created) */
int korusysfs_file(const char *path, const char *content);
/* symlink /sys/<path> -> /sys/<target>, stored relative as on Linux */
int korusysfs_link(const char *path, const char *target);

/*
 * A device directory /sys/devices/<devpath> with its uevent, a subsystem link
 * to /sys/<subsys> ("bus/pci", "class/input", ...), the matching
 * /sys/bus/X/devices/<name> or /sys/class/X/<name> link, and, for a character
 * device (devnum "M:m", may be NULL), the dev attribute and /sys/dev/char/M:m.
 * subsys may be NULL (e.g. /sys/devices/platform).
 */
int korusysfs_device(const char *devpath, const char *subsys,
		     const char *uevent, const char *devnum);

#endif
