---
name: kmod-loader
iface: koruos/kernel.kmod
arms: [koru-native]
lane: native-zig
needs: [module-transport]
accept: a provider ELF loads into a fresh domain at runtime and its realize row binds — a driver arrives without reboot
tier: qemu
status: open
evidence: —
peer: —
provenance: —
---

# kmod-loader

Runtime provider load: module-transport already carries ELF payloads
to children — the missing half is *binding* a loaded module's realize
rows into the live syscall/provider table. The .kext/LKM shape CC
asked about, honestly scoped: a provider module loads into its own
domain (not kernel space), and its declared iface row routes.

## Acceptance

Boot a minimal kernel minus one provider (e.g. no pty); a module
payload arrives via cpio/door, binds its row, and a child opens the
previously-refused capability — the same call that refused before
now answers. Serial evidence, status=0.

## Notes

- Domain-bound, not in-kernel: a "module" is a provider running in a
  protected domain with a door, matching the silo doctrine — never
  shared text into kernel space.
- Pairs with `kernel-profile` (install-time specialization) — this
  is the runtime half of "compile/load only what this machine needs".
- CC's resource-bridge dylib-refresh is the same shape a level up;
  the bridge vocabulary becomes a bindable module itself.
