---
name: kernel-profile
iface: koruos/kernel.profile
arms: [koru-native]
lane: native-zig
needs: []
accept: a build manifest names providers; the kernel compiles only them — a slimmer image boots on the same serial evidence
tier: qemu
status: open
evidence: —
peer: —
provenance: —
---

# kernel-profile

The source-distribution kernel: ~20% of a distro kernel ever
executes on a given machine — ours shouldn't ship the other 80% at
all. A build manifest names the provider set (drivers, protocols,
surfaces); `build-native` compiles exactly that set, and a machine-
tailored image is smaller by construction, not by dead code.

## Acceptance

A profile manifest listing a minimal provider set (no usb, no gpu,
no pty) builds a measurably smaller ELF that still boots `boot_hello`
+ the realize rows it kept — a refused provider's syscall answers
with the named refusal, not a missing arm crash.

## Notes

- The realize rows already make provider selection declarative —
  this slot wires that down into the zig build: providers become
  build-time selectable units, not one monolith.
- Pair with `kmod-loader` for the runtime half; profile alone is
  the install-time half (a custom kernel per machine, compiled at
  install).
- CC's "compile incrementally by usage" is the far edge — file
  demand-paging-of-kernel-code there, not here.
