---
name: netsock-relay
iface: koruos/net.socket
arms: [koru-native]
lane: native-zig
needs: [sessions-jobctl]
accept: AF_INET stream socket end-to-end — connect/HTTP/EOF against a real host TCP service through the COM2 bridge; ECONNREFUSED negative
tier: qemu
status: landed
evidence: V
peer: koru-desktop/providers/net-virtio-lwip (reference, not source)
provenance: host-side halves are project Python (tests/netrelay.py, tests/llmstub.py)
---

# netsock-relay

The AF_INET socket surface, real end to end, with the TCP stack
*placed* on the host — delegation, not a netstack (see
`concepts/frag-delegated-stack-is-stack-placement.md`; `net-virtio`
remains the honest in-kernel-stack rung).

## Shape

`socket(AF_INET, SOCK_STREAM)` mints a `SockPair` whose peer end is
owned by a kernel bridge sentinel — every existing pair arm
(read/write/send/recv/sendmsg/poll/close/EPIPE) works unmodified.
`connect(sockaddr_in)` frames `CONNECT{ip,port}` onto COM2 and parks;
the host relay (`netrelay.py`, riding QEMU's second `-serial` as a
TCP chardev on :4567) dials one real TCP connection per session id
and answers `COK`/`CERR`. Frames: `0x4E|id|op|len:u16le|payload`,
ops CONNECT/DATA/CLOSE/SHUT guest→host, COK/DATA/EOF/RST host→guest.
IRQ3 rides the IOAPIC (no MADT ISO exists — routed explicitly).

## Acceptance — MET (QEMU serial, `NET COMPLETE fails=0`)

`boot_netsock` → `netsock.cpio` `/bin/nettest` (static musl C):

- `refused-rc got=-1` / `refused-errno got=111` — connect to a dead
  port returns `ECONNREFUSED` through the relay's CERR path
  (Windows `WinError 10061` → POSIX 111 host-side, not truncated).
- `socket`/`connect got=0` — pair mint + handshake park→COK.
- `send`/`poll`/`recv-bytes`/`http-200 got=1` — `GET /v1/models`
  answered `HTTP/1.1 200` by a live service across the bridge
  (llama-server on :1234 when owned, `llmstub.py` otherwise).
- `eos got=1` — `Connection: close` surfaced as relay EOF.
- `close got=0` — CLOSE frame on teardown.

`klanker-child` rides it further: `KL chat rc 0` — an unmodified
`klanker chat` turn completes a real SSE `chat/completions` exchange
through the bridge (proven against the live qwen3.5-4b llama-server;
the gate's `llmstub` speaks the same SSE shape hermetically).

## Refusals kept loud

- `SOCK_DGRAM`/`SOCK_RAW`/other families → `-97 EAFNOSUPPORT`.
- `setsockopt` → `-92 ENOPROTOOPT` (Linux's own word) except
  `TCP_NODELAY`, accepted — the bridge never coalesces, so the
  semantics are already true. See
  `concepts/frag-the-errno-name-is-the-contract.md`.
- `getsockname` → `sockaddr_in{AF_INET, 0.0.0.0:0}` (host owns the
  local end); `getpeername` → the CONNECT-named peer or `-107`.
- `SO_ERROR` answers the handshake errno; `shutdown(SHUT_WR)` frames
  host-side half-close.

## Kernel surface this rung forced

- `SockPair` grows `fam`/`nid`/`cst`/`cerr`/`wshut`/`rst`/`npeer`;
  `sockCloseEnd` sends CLOSE when the child end of an inet pair dies.
- `canonNr` folds 48/54 (shutdown/setsockopt) + 51/52 (sockname) into
  channel class 22 — already in the bot bag; no new grant class.
- `select`(23)/`pselect6`(270) arms — CPython's timeout path speaks
  them; they resolve through the existing poll machinery (the sigmask
  operand is the same stored-fact ruling as `ppoll`).
- `netInit` probes COM2 (`LSR==0xFF` → unarmed, so single-`-serial`
  boots are untouched) + IRQ3 dispatch + tick drain.
