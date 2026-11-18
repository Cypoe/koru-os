---
type: belief
id: frag-ancillary-fds-arrive-in-order
provenance: koru-os native session — cage 0.1.5 nested compositor, 2026-11
ts: 2026-11-17
tags: [native, unix, scm-rights, wayland, oracle, contract]
---

**Ancillary file descriptors are an ordered channel, and the order is
protocol semantics.** Cage sends its frame-pool fd and cursor-pool fd
in two successive `sendmsg` calls, each carrying one SCM_RIGHTS fd.
Our `recvmsg` drain popped the queued refs LIFO: when both sends
landed before one receive, the receiver saw `[cursor, frame]`.
libwayland's demarshal then handed `wl_shm_pool.create` the 640-byte
cursor pool where the 1280×720 frame pool was declared — the bounds
check failed, `wl_client_post_no_memory`-adjacent protocol error, and
the compositor connection died with no posted `wl_display.error` —
just a silent "error in client communication".

The oracle (unmodified upstream cage) caught what every single-fd
client — foot, wlserver's own helpers — could not: a queue discipline
that is only wrong when two descriptors arrive in one drain. FIFO is
the contract; the send order IS the message.

Held consequence — fd passing composes with everything else on the
channel. A compositor's pool/FD choreography is its hot path; any
reorder is a protocol violation even when the count is right.
