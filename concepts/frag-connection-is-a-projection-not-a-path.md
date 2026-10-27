---
type: belief
id: frag-connection-is-a-projection-not-a-path
provenance: koru-os native session — wl protocol pair rung, 2026-10
ts: 2026-10-27
tags: [native, socket, spawn, fd, wayland, compositor, connection, contract]
---

**A connection is an fd-table fact, not a path.** The wl pair rung
proves the compositor model without a single pathname: `wlinit.elf`
`socketpair`s, then two `spawn_start`s project each end into a
SEPARATE binary's fd0 — `wlserver.elf` and `wlclient.elf` speak real
libwayland wire format over it (registry globals, shm formats,
surface/shm_pool/buffer objects, the pool fd crossing SCM_RIGHTS,
attach/damage/frame/commit answered by callback.done + release, and
a display.sync roundtrip). Wire correctness never required
`$XDG_RUNTIME_DIR/wayland-N`.

Held consequence for the next rung: **pathname endpoints —
bind/listen/accept on `wayland-N` — are a discovery layer over this
primitive, not the primitive itself.** A socket node in the fs view
resolves to an endpoint mint the same way `openobj` resolves a key to
a handle; the listen backlog is a pending-projection queue. Do not
build ad-hoc "socket handoff" verbs: the projection mechanism already
carries any fd a spawner can name, and the EOS semantics measured here
(server exits on last-far-end-close) are exactly what a real session
relies on.

Evidence: `WLSRV magic=deadbeef tag=00c0ffee px0=5a` — the server
reads the client's pixels through the SCM_RIGHTS'd pool it mmap'd
MAP_SHARED; `WLCLI frame done=42` / `sync done=43` / `buffer release`
/ `WLSRV EOS` / `WLINIT srv=0 cli=0`. Measured uniprocessor and under
`-smp 4` with both children rotating claims across APs. Boot gate
63/63 (`boot_wl` + `wlpair` rows).
