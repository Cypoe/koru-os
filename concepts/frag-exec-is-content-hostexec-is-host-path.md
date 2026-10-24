---
type: belief
id: frag-exec-is-content-hostexec-is-host-path
provenance: hosted spawn seam, e98ed09+ (koru/hosted/linux.zig koru_spawn_host)
ts: 2026-03
---

`spawn:exec` and `spawn:hostexec` differ in what crosses the seam, and
that difference IS the identity story.

`exec` takes image **bytes**. The content is the object: ext2 reads it
by path→inode, the nid store binds the foreign name `ext2/d<dev>/<ino>`,
and the bytes can move to any provider unchanged. Identity is
content-addressed and owned by koru-os.

`hostexec` takes a **path in the provider's own namespace**. No bytes
cross; the host kernel resolves and loads. Identity is the host's name —
a `/usr/bin/python3` that exists only because the host fs says so. This
is why it is hosted-only: koru-native has no host namespace, so the verb
refuses at link rather than pretending.

Consequence for the seam's evolution: any future "exec a host program
with real argv/env" work extends `hostexec`'s wire shape (argv-as-data),
not `exec`'s — and any future native exec keeps acquiring bytes through
our own fs (ext2 today), never a path in somebody else's namespace.
