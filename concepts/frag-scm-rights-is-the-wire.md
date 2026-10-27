---
type: belief
id: frag-scm-rights-is-the-wire
provenance: koru-os native session — unix-socket transport rung, 2026-10
ts: 2026-10-27
tags: [native, fd, socket, scm-rights, memfd, mmap, wayland, transport, contract]
---

**SCM_RIGHTS is not a feature of the wire — it IS the wire.** Wayland
shm pools, keymaps, and dmabufs exist only as fds carried in ancillary
data; the WSLg byte-pump oracle already proved they die in a pump
without fd passing intact. So the honest intermediate toward
libwayland-unmodified is **real unix semantics, not a koru-shaped
equivalent**: nr288 `socketpair` mints a refcounted duplex ring pair,
nr46/47 `sendmsg`/`recvmsg` carry `SCM_RIGHTS` in a real `cmsghdr`,
nr319 `memfd_create` + `ftruncate` + `MAP_SHARED` mmap gives the shm
pool the protocol expects. An fd in flight is a *capability reference
transfer*: sendmsg dup-refs the projected endpoint into a per-direction
queue, recvmsg mints a NEW fd-table projection of the same endpoint in
the receiver — the number differs, the endpoint doesn't. A protocol
that "passes fd numbers" is protocol-shaped output, the thing the
no-fake-compositor rule exists to refuse.

MAP_SHARED is one frame set, not a copy: `ShmObj` owns page frames with
a refcount; mmap pins the SAME frames into whichever CR3 asks, so two
processes write/read one object. `ShmObj` frames outlive any one
mapping — release walks the object's frame list, not a process's PTE
range.

Oracle lesson paid in this rung: **fd-table slots can never encode an
endpoint identity as the bare index** — slot value `0` is the empty-fd
sentinel every check tests, so an endpoint stored at index 0 is
indistinguishable from "no fd" (observed `mmap e=9` EBADF on a
perfectly live memfd). Encodings are index+1. The same latent
collision existed for socket pair 0 — the bug class is "table index
vs. sentinel", not this one site.

Evidence: `wlpair.elf` (musl, real ELF) `socketpair`+`fork`s, client
`sendmsg`s `wl-go` + the memfd through `SCM_RIGHTS`, server `recvmsg`s
`bytes=5:wl-go rfd=5`, mmaps the received fd `MAP_SHARED`, reads the
client's `magic=deadbeef tag=00c0ffee` back through the shared pool —
measured uniprocessor and under `-smp 4` with both children rotating
claims across APs. Boot gate 61/61 (`boot_sock` + `sockpair` rows).
