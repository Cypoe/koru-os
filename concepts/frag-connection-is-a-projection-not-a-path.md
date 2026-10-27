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

Held consequence — realized: **pathname endpoints —
bind/listen/accept on `wayland-N` — are a discovery layer over this
primitive, not the primitive itself.** Landed exactly as ruled:
`bind` mints a real `S_IFSOCK` inode through the provider's `mknod`
verb (debugfs sees `wayland-1` on disk) and registers a
`(view-ctx, object-key)` listener — the same identity pair `openobj`
resolves; `listen` opens the backlog; `connect` resolves the path
through the caller's fs view (ENOENT for no name, ECONNREFUSED for a
name with no live listener — the unix distinction) and mints a session
pair whose server end queues as a pending projection; `accept` pops it
into a fresh fd table slot. No handoff verbs were built — the backlog
is literally a queue of fd values awaiting projection. The socketpair
fixture's EOS semantics carried over unchanged: the server exits on
last-far-end-close over a session it never inherited.

Evidence: `WLSRV bound wayland-1` / `WLCLI connected tries=0` /
`WLSRV accepted fd=4` — the rendezvous ran through the path, not a
spawn-wired fd — then `WLSRV magic=deadbeef tag=00c0ffee px0=5a`
(pixels through the SCM_RIGHTS'd MAP_SHARED pool), `WLCLI frame
done=42` / `sync done=43` / `buffer release` / `WLSRV EOS` /
`WLINIT srv=0 cli=0`. Measured uniprocessor and under `-smp 4` with
server and client claimed on different APs. Boot gate 63/63 (`wlsock`
row).
