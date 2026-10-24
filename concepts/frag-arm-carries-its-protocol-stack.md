---
type: belief
id: frag-arm-carries-its-protocol-stack
provenance: koru-os hosted session — linux-wayland arm, 2026-10
ts: 2026-10-24
tags: [hosted, wayland, vendoring, realization-arm, surface]
---

A realization arm carries its own protocol stack when the host's
shared libraries are the wrong version — and "carries" means
**vendored source compiled in**, not a staged `.so`.

Measured on `linux-wayland`: the generated wayland bindings call
`wl_proxy_marshal_flags`, which the host's libwayland (Ubuntu 20.04,
1.18) doesn't export — it arrived in 1.20. The vroot's 1.26
`libwayland-client.so.0` exists but demands glibc 2.38/DT_RELR, which
the host's 2.31 loader refuses. Both dynamic routes close at the same
point: **the protocol the arm speaks and the libc the lib was built
for must agree with the same host — and they don't.**

So the arm vendors the stack: scanner-generated protocol glue +
libwayland-client `src/` (1.26.0) + a musl `libffi.a`, compiled into a
musl-static binary by `build-hosted.sh shim=linux-wayland`. Zero
runtime deps — the same binary runs on the host and inside the vroot
jail unchanged, because the jail is never in the picture: the wire
protocol is the same either way.

Held consequence: **the provider is the contract; the host's
libraries are an accident of the environment.** Where an arm's
protocol predates or postdates what the host happened to install, the
arm brings its own. This extends the vroot doctrine one step inward —
`frag-vroot-jail-membrane` vendors userspace programs; this vendors
the provider's own wire stack.

Caveat kept honest: vendored-static is for *wire* stacks (wayland,
libffi — no device state). A GPU/driver path can't be vendored the
same way — dmabuf needs the compositor to actually speak it.
