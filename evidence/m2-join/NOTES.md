# M2 upstream-lane join — unmodified modetest on /dev/dri/card0 via korukms

VERDICT: GREEN — Debian modetest (unmodified, m6 rootfs) opens
/dev/dri/card0 served by the upstream korukms provider bound to
virtio-gpu-pci, enumerates Virtual-1 640x480, and the modeset paints
real pixels: QMP screendump shows a non-black color band.

Run: /tmp/drm-join image (unikraft 0.21 stable + app-elfloader +
lib/korukms@{korukms-virtio-gpu} + lib/korusysfs + m6 rootfs with
modetest/libdrm2/glibc2.41 — pins in koru-desktop
providers/drm-virtio-gpu/m6-image/origins.lock).

QEMU: -cpu max -m 512M -vga none -device virtio-gpu-pci -append
'modetest -s 34:640x480' -serial file -monitor unix -display none.
-vga none removes the bochs/stdvga so virtio-gpu binds card0 (both
providers race on the default VGA otherwise → kms_rows_bind -EBUSY).

Serial highlights (serial.log):
- koru-os: INFO sysfs view on /sys: 21 entries, 0 errors
- trying to open device '/dev/dri/card0'... done
- opened device `koru-os kms personality (provider bochs-display)` on
  driver `korukms` — name string is cosmetic (JOIN.md delta 3); the
  bound device is virtio-gpu (only display present, -vga none)
- setting mode 640x480-211.59Hz on connectors 34, crtc 32
- koru-os: REFUSED linux.ioctl.DRM_IOCTL_MODE_SETGAMMA (expected — no
  gamma hw; modeset still completed)

Screendump (/tmp/m2u.ppm, 640x480 — ppm is gitignored): 1024 non-black pixels in the top
rows — the partial color-bar band documented in JOIN.md (18432 px
there; capture timing varies — modetest exits and the scanout keeps
the last transferred rows).

Upstream fixes needed by this run (committed on this branch):
- lib/korusysfs: mkdir /sys before ramfs mount — the embedded initrd
  leaves no empty /sys, mount() returned ENOENT, libdrm device
  enumeration found nothing ("no device found").

Scratch-only fixes (vendored .unikraft tree, not committed):
- ukboot/boot.c ctorfn argc/argv call cast (clang 21 strict protos)
- UK_CFLAGS -Wno-error=incompatible-pointer-types,int-conversion
