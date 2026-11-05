---
name: gpu-virgl-3d
iface: koruos/kms.gpu3d
arms: [koru-native]
lane: native-zig
needs: [drm-virtio-gpu]
accept: virgl GLES command stream — a real draw call executed by the host
tier: qemu
status: open
evidence: —
peer: koru-desktop/providers/gpu-virgl-3d
provenance: —
---

# gpu-virgl-3d

virgl over virtio-gpu: 3D command stream to the host's real GL —
the honest GLES path for QEMU *before* any physical-GPU DRM exists.
This is what makes Hyprland's GLES-only renderer reachable on qemu
tier without pretending a 2D card does 3D.

## Acceptance

`-device virtio-vga-gl -display egl-headless`: a real draw call
executed — a triangle through the virgl command path, pixels verified
on scanout. Then EGL/GLES surface creation for a real client.

## Notes

- The key insight from the provider census: virgl lets Hyprland-as-
  oracle run in QEMU today; real DRM/GLES hardware is the hw tier.
- mesa/virglrenderer on the host side is the peer; our side is the
  virtio 3D command channel.
