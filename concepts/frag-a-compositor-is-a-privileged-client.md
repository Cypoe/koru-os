---
type: belief
id: frag-a-compositor-is-a-privileged-client
provenance: koru-os native session — wlscene rung, 2026-10
ts: 2026-10-28
tags: [native, surface, compositor, capability, fd, wayland, scene, contract]
---

**A compositor is a privileged client, not kernel code.** The scene
seam is three child-visible nrs gated by their own bag bit (class 59 —
"may mint display surfaces", a compositor's cap no ordinary client
holds): `surf_open` mints the `*Surf` through the provider and returns
it as a `.surf` fd-table projection; `surf_blit` copies a rect of the
child's own pixels into the provider's retained backing (rows bounce
through one kernel page — a stride over the page refuses, user VA is
read via copyFromUser, never trusted across the provider boundary);
`surf_present` commits damage through the z-stack. There is NO
`surf_close` nr — **the surface's release verb is `close(fd)`**: last
ref detaches from the scene and comp repaints the vacated rect, so a
dying compositor's surfaces can never leak onto the scanout. dup
shares the token under the refcount; fstat answers chrdev (a handle on
the scene, not a byte channel); read/write refuse EBADF — the surface
is an endpoint that accepts blits, not a stream.

Held consequence — the custody ruling stays provider-side: **commit
copies**. `wl_surface.commit` blits the client's shm bytes into
provider-owned backing at commit time; the client may scribble its
pool afterwards and the scene is already correct. That is exactly
weston's shm-path semantics (the composite reads the buffer at commit,
damage decides what) — and it sidesteps the cross-CR3 problem
honestly: the compositor reads its own MAP_SHARED mapping, the kernel
copies into provider custody, the provider owns what the z-stack
composites. Zero-copy import of client frames belongs to the
dmabuf/drm rung, not shm.

Fixture lesson paid for: **a pool must hold the buffer it backs.** The
clients declared 64x64x4 (16KiB) buffers on 4KiB memfd pools — fine
while nobody read past page 0; the first consumer of the full declared
geometry (the commit-blit, reading row 15+) faulted honestly with
EFAULT. Declared wire geometry is a contract the pool must satisfy —
undersizing is a latent client bug, not a kernel problem.

Evolution (input+multi-surface rung) — the privilege has a second
member: **the compositor owns the machine's input, and what a client
receives is a projection the compositor decides.** `input_open`
(class 55 — "may drain the input rings") mints an evdev-shaped fd:
`read` yields `InEv` records off the merged provider rings, `poll`
reports POLLIN through a non-destructive pending predicate, IRQ-side
`koru_input_wake` marks `.input`-waiters the same way every other
endpoint's mutation site does. The kernel does NOT route events to
surfaces — hit-testing is compositor policy exercised in its own
address space: wlserver tracks the pointer, scans the z-ordered
surface list it minted, and emits `wl_pointer.enter/motion/button`
and `wl_keyboard.key` to the focused session only. Placement is the
same shape — `surf_move` is the compositor's placement verb (old+new
damage rides the provider), and a button-held drag is the compositor's
call to make, not a client's request to grant. Clients never see the
rings; the kernel never sees focus. That is the seat's real shape:
**one owner reads hardware, every client hears decisions.**

Fixture lesson paid for: **a compositor's fd table is real** — two
sessions + listener + input + pools + SCM arrivals overran the 8-slot
toy table (EMFILE on surf_open, silent CTRUNC on the received pool
fd); the table is now 32. And *unbuffered logs are a gate bug*: an
injector chasing serial evidence watched a fully-buffered stdout that
only flushed at exit — `setvbuf(_IONBF)` is evidence hygiene, not
cosmetics.

Evolution (libwayland-server rung) — **the protocol stack is inert**:
swapping the compositor's wire implementation for vendored upstream
libwayland-server 1.26 (real `wl_display`/`wl_global`/`wl_resource`
impls, real demarshal, real `wl_shm` via `wl_display_init_shm`)
changed nothing about where the privilege lives. The library owns
object tables, dispatch, and the shm pool lifecycle; the seam still
owns the scene caps (59) and the input cap (55) — and the resource
callbacks are the only place those caps get spent. A real compositor
binary is a *capability-spending policy body over a shared protocol
library*, which is exactly the wlroots/swayweston shape. What the
stack actually cost the kernel was channel-layer, not
compositor-layer: `epoll_*`+`epoll_pwait` and `eventfd(2)` fold into
class 22 ("may wait on channels") — an interest list and a counted
semaphore are channels a non-compositor may also hold — and
`getsockopt(SO_PEERCRED)` answered by `SockPair` sides remembering
their minter's roster id. Fixture lesson paid for: **a session count
captured before `wl_event_loop_dispatch` is stale the moment the loop
runs** — accept mints and EOS frees *inside* dispatch; a compositor
that decides quiescence from the pre-dispatch count kills the client
it just accepted (EOS with no log, since the only destroy paths that
log are wire errors).

Evolution (xdg_shell rung) — the privilege's third member is **role
adjudication**: a bare `wl_surface` is not a lawful scene object.
`xdg_wm_base` is the role factory a real client binds; a toplevel
exists only after the handshake — the client's initial buffer-less
commit is answered by `toplevel.configure` + `xsurface.configure`
(serial), and a buffer commit is lawful to present only after
`ack_configure`. An unacked buffer commit is a protocol violation the
compositor names and refuses to present — the seam's loud-refusal
discipline now lives inside userland protocol, not just at syscalls.
Placement gained its client-initiated form: `xdg_toplevel.move` is a
request the compositor OWNS — it binds the grab to the requesting
surface until release, the same drag the compositor can start on its
own binding. And liveness is a channel, not a hope: `ping`/`pong` is
the compositor's death clock for a session. The client side carries
the mirror lesson: **wire truth lives in the generated tables, not
memory** — an opcode remembered as 4 when the protocol says 5 is a
request that parses as a different request entirely (`move` arriving
as `show_window_menu` reads as silence, not an error).

Evidence: `wlserver.elf`'s commit handler drives the real scene —
`comp: attach 64x64 at 40,40`, `surf: open`, `paint nb=3` (the
composited stack), `detach` + reveal on EOS-close — and the
screendump at the serial-printed anchor reads the client's pixels off
the virtio-gpu scanout: `adbeef` at (0,0), `c0ffee` at (1,0), `5a` in
(0,1)'s blue, black root outside. Two libwayland clients, two
*Surfs — each through the full xdg handshake: `ping`/`pong`,
`toplevel configure ser=N` → `WLR xsurf conf` → `ack N` → buffer
commit → slot mint → `blit=0/0 present=0/0`. Injected
`mouse_move`/`mouse_button`/`sendkey` land as `ptr enter/motion/
button` and `kbd key` on the focused session only; a press lands the
client's `xdg_toplevel.move` (`WLSRV tl-move slot=N`) and the grab
prints `WLSRV move 160,155`; the screendump reads `adbeef`/`c0ffee`
at the MOVED rect with both original tiles black. Boot gate `wlscene`
+ `wlscene-pixels` rows — pixels, not serial, are the oracle.
Post-swap evidence: the same `wlserver.elf` now drives sessions
through real libwayland-server — `epoll_pwait`-paced dispatch fires
`wl_client_create` (SO_PEERCRED answered) on the accepted fd, the
library's own registry emits all four globals, `wl_shm` is the
library's v2 global, and unmodified libwayland-client 1.26 fixtures
complete registry→xdg→commit→frame→release→EOS unchanged; the
injected-input → per-focus pointer/key → nr519-drag → moved-rect
pixel chain survives the swap untouched.
