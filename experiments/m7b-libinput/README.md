# M7b: libinput on the koru-os sysfs view (B15)

DESIGN-0001 §0.4 "M7b acceptance" (frozen 2026-10-19 15:07 CEST in `52a0629`, before the runs).
**PASS 3/3 under TCG, 2026-10-19 15:07 CEST** on the M7b kernel (sha256
`3500350987d3c9a19b93d2cb7e50f578825b5b8311041c45d72ce01c4d4c6bf4`, 674,480 B, built by
`experiments/m7-input/build-image.sh` with `lib/korusysfs` and the fstatat patch). Regressions
M3, M4 (a)–(d), M5a, M6, M7a, M8a, M8b: 3/3 each, 15:07–15:13.

## What B15 resolved to

libinput's path backend (`debug-events --device`) needs, per strace on the L1 oracle
(`evidence/l1-debian/libinput.strace`): `/sys/dev/char/13:64` resolving to the device directory,
its `uevent` and `subsystem` symlink, the same two files for every ancestor up to
`/sys/devices/platform`, and the udev database record `/run/udev/data/c13:64` carrying
`ID_INPUT`, `ID_INPUT_KEY`, `ID_INPUT_KEYBOARD`. It reads no capability attribute (bitmaps come
from evdev ioctls) and no DRM node in the path backend.

Two decisions:

1. **The sysfs view is written by the kernel** (`lib/korusysfs`, ramfs mounted on `/sys` at a
   late initcall). A provider publishes its own hardware nodes and names its node in the row
   (`input_provider.sys_parent`, `kms_provider.sys_parent`); a personality publishes the class
   device under that node. `ps2kbd.c` publishes `platform/i8042/serio0`, `evdev_linux.c` publishes
   `input/input0` (the Linux `input_dev_uevent` lines, attributes, capabilities, id) and
   `input0/event0`; `bochs.c` publishes the PCI device with attributes from config space,
   `drm_linux.c` publishes `drm/card0`. A driver silo fills the same row fields, so Q28 stays open.
2. **libudev is libudev-zero** (ISC, https://github.com/illiliti/libudev-zero, pinned commit
   `8f1d3d0624496f1c4967f18d6afaddbd552d8bce`, `build-libudev-zero.sh`), built with the
   `LIBUDEV_183` symbol version so the unmodified Debian binaries bind to it. It reads `/sys`
   directly and derives `ID_INPUT_*` from the uevent bitmaps, so there is no udevd and no
   `/run/udev` database. The L1 twin with the same library (`evidence/l1-zero/`) produces the
   identical `udevprobe` output, and its `ID_INPUT*` properties match the record systemd-udevd
   257 wrote on L1 (`evidence/l1-debian/udevdb-c13_64.txt`).

Debian's own `libudev.so.1` (systemd 257) cannot resolve any device on koru-os: its path code
needs `statx` with `STATX_MNT_ID`, `name_to_handle_at`, `O_PATH` symlink fds and `/proc/self/fd`
(B16, `evidence/probe-koru-debian-libudev/`). Not needed for M7b.

Also fixed on the way: vfscore's `newfstatat` ignored `AT_SYMLINK_NOFOLLOW` for absolute paths,
so glibc `lstat()` followed symlinks (`patches/unikraft-0.21-vfscore-fstatat-nofollow.patch`);
set 1 code 0x54 now reports `KEY_SYSRQ` as Linux `atkbd` does.

## How to run

```
experiments/m7-input/build-image.sh                 # W= for the build dir
experiments/m7b-libinput/build-libudev-zero.sh <dir>
experiments/m7b-libinput/run-m7b.sh <kernel> <busybox> <m7bin root> <libudev.so.1> <outdir>
```

`<m7bin root>` is `apt-get download libinput-tools libinput10 libinput-bin libevdev2 libmtdev1t64
libwacom9 libwacom-common` (Debian 1.28.1) extracted; glibc and the other dependencies come from
the box (`mkroot.sh`). The image has mount points `/sys` and `/run`. Keys arrive through QMP
`input-send-event` (`drive.py`) after libinput prints `DEVICE_ADDED`.

The L1 oracle (`run-l1.sh`, `LIBUDEV=debian|zero`) boots Debian `linux-image-6.12.113` +
`evdev.ko` + the bochs-drm modules, runs systemd-udevd 257 (`apt-get download udev
libsystemd-shared`) and the same libinput binaries under strace, and dumps the udev database and
the sysfs uevents. It never counts as a pass.

## Results (3/3, 15:07)

| check | result |
|---|---|
| (b1) sysfs view | `sysfs view on /sys: 60 entries, 0 errors`; uevents of event0 and card0, subsystem links, `/sys/dev/char` and `/sys/class` links equal L1; input0 bitmaps match L1 (`KEY` 106 codes, subset of L1's 145) |
| (b2) libudev view | all 33 `udevprobe` lines for event0, card0 and the drm enumeration equal the L1 libudev-zero twin; `ID_INPUT`, `ID_INPUT_KEY`, `ID_INPUT_KEYBOARD` = 1 as udevd wrote them on L1 |
| (b3) libinput | one `DEVICE_ADDED` (`seat0 default group1 cap:k`); 18 `KEYBOARD_KEY` lines equal the derived sequence and both L1 runs |
| (b4) refusal log | the M7a rows only (brk, rseq, set_robust_list, two STUBBED lines) |
| (b5), (x) | no crash; disk byte-identical; e2fsck clean |

Known, accepted differences to L1: device name (`koru-os i8042 keyboard (set 1)` vs
`AT Translated Set 2 keyboard`), 106 vs 145 key codes, koru-os's own `DRIVER=` names, no
`/dev/input/mice`, no DMI node (libinput's DMI quirks match nothing on QEMU anyway).

## Not in M7b

udev monitor/hotplug (netlink), seats and `ID_SEAT`, a udev database and rules, systemd's libudev
(B16), DMI, sysfs attributes nobody read, write access to `/sys`.
