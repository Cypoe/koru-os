---
type: belief
id: frag-the-errno-name-is-the-contract
provenance: koru-os native session — klanker chat over AF_INET, 2026-11
ts: 2026-11-16
tags: [native, errno, refusal, oracle, abi, cpython]
---

**A refusal with the wrong errno name is still a wrong answer.** The
chat path's last wall was `urlopen error [Errno 95]` — our
`setsockopt` arm returned `-EOPNOTSUPP` for every option, loudly and
honestly by our own reading. But CPython's `http.client` calls
`setsockopt(IPPROTO_TCP, TCP_NODELAY)` after every connect and
tolerates exactly one errno: `ENOPROTOOPT` (92). `EOPNOTSUPP` (95)
re-raises and kills the request. Both names mean "we don't do that";
they are not interchangeable — the consumer's *tolerance set* is part
of the ABI.

The ruling that came out of it is sharper than "always refuse
loudly": **the refusal must name the errno the Linux twin would name
for that call on that socket type.** For options a socket level
doesn't define, Linux's word is `ENOPROTOOPT`. For an operation the
socket's type doesn't carry (getpeername on an unconnected end,
shutdown on a unix pair), it's `ENOTCONN`/`EOPNOTSUPP` as the case
demands. The oracle isn't "does it refuse" — it's "does the real
consumer survive the refusal the way it survives Linux's".

And the dual of the lesson: **sometimes the honest answer is accept,
not refuse.** `TCP_NODELAY` on the relay stream isn't a capability we
lack — the bridge frames a guest write the moment it lands, so
disabling Nagle is already the behaviour. Accepting it returns truth;
refusing it would have been a louder *lie*. The refusal axis is for
semantics we genuinely don't realize, not for flags whose semantics
we already exceed.
