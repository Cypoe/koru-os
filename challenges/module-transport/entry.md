---
name: module-transport
iface: koruos/module
arms: [koru-native]
lane: native-zig
needs: []
accept: gate row iso-mod — GRUB module2 -> mb2 tag3 -> CPL=3 child, status=42
tier: qemu
status: landed
evidence: M
peer: —
provenance: original; GRUB oracle taught module!=module2, tag string is cmdline
---

# module-transport

Multiboot2 tag-3 modules: pmm reserves the loader's payload pages,
`koruos/module` exposes them by cmdline name, `exec` spawns the bytes
as a real ELF child. The transport the initramfs rides.

## Acceptance

Gate row `iso-mod`: `module2 /boot/musl-mod.elf musl-mod.elf` —
pmm prints the tagged range, child prints `musl child says hi`,
exit status 42 through the spawn seam. PVH arm honestly refuses
(modules are a loader concept).

## Notes

- `module` is the mb1 spelling — refuses "you need to load the kernel
  first" under mb2. `module2` is the mb2 command; its string field is a
  cmdline, not the path (frag-module-is-a-tagged-range-not-a-file).
