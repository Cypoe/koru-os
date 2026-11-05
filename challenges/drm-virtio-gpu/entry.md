---
name: drm-virtio-gpu
iface: koruos/kms.drm
arms: [koru-native]
lane: native-zig
needs: [virtio-pci-modern]
accept: DRM-shaped provider: dumb create/map + modeset + page_flip on virtio-gpu
tier: qemu
status: open
evidence: —
peer: koru-desktop/providers/drm-virtio-gpu
provenance: —
---

# drm-virtio-gpu

A DRM-shaped provider over the existing 2D virtio-gpu path: dumb-buffer
create/map (the mmap'd *Surf precedent already proves the shape),
mode setting, atomic-ish page flip. The ABI shape libdrm expects —
what Hyprland's wlroots DRM backend will demand of us.

## Acceptance

A libdrm-speaking client does dumb_create+dumb_map+modeset+page_flip
against the provider — a real modeset on the virtio scanout, pixel
evidence via screendump.

## Notes

- gpu.zig already does 2D scanout (vgpu rows green) — this is the
  ABI-shape layer, not new hardware.
- GBM/EGL render node stays refused until gpu-virgl-3d — honest gap.
