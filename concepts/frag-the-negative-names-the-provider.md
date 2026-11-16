---
type: belief
id: frag-the-negative-names-the-provider
provenance: koru-os native session — net-virtio rung, 2026-11
ts: 2026-11-17
tags: [native, net, oracle, errno, provider, honesty]
---

**A negative assertion names the provider, not just the failure.**
The relay oracle's refused-connect check asserts `ECONNREFUSED` (111)
because a real host TCP stack answered the delegated connect with a
real RST. Run the identical test binary against the owned virtio
stack and the same logical failure — "nothing listens there" —
comes back `ETIMEDOUT` (110): QEMU's slirp drops SYNs to dead host
ports silently, and our stack's retransmit sweep times out honestly.
Asserting 111 on the native row would have forced a lie into the
stack (fabricate RSTs) or a lie into the oracle (expect a name the
provider never produces).

The ruling: each provider's negative is whatever *its* wire truth
can prove — for the native row that's `EHOSTUNREACH` (113) from an
ARP that never answers, a failure entirely inside our own stack and
therefore deterministic. The two oracle binaries share the socket
seam but not the assertions: `nettest.c` expects 111 (the host's
word), `netvtest.c` expects 113 (our word). Same syscall, different
provider, different honest answer.
