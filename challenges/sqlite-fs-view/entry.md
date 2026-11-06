---
name: sqlite-fs-view
iface: koruos/fs.sqlite
arms: [koru-native]
lane: native-zig
needs: []
accept: a ChildFsOps provider backed by SQLite — POSIX verbs translate to queries; a child reads/writes paths
tier: qemu
status: open
evidence: —
peer: —
provenance: SQLite is public-domain — the cleanest possible lift
---

# sqlite-fs-view

The curated-store idea CC floated (SQLite as the filesystem, POSIX a
view over it) is our shape exactly: `ChildFsOps` is already a view,
not a store. This provider answers open/read/write/stat over tables —
`files(path, blob, meta)` — with the POSIX illusion costing exactly
what it costs (no free rename atomicity, no xattrs, honest limits).

## Acceptance

A musl child creates/writes/reads/stat's paths that resolve to rows;
a second child sees the same store through its own scoped view.
Rename lands as a row move. Serial evidence lines, status=0.

## Notes

- Honest constraints to state in-code: directory synthesis, hardlink
  semantics (row alias vs inode), fsync/flock translation.
- The relational-filesystem doctrine (memory: relational-filesystem)
  is the long-form version — this slot is the minimal measurable
  slice: one table, real verbs, real refusal where POSIX can't map.
- deltadb (zed) is the alternative backend CC mentioned — file under
  Notes, not a separate slot until measured.
- Sibling lane: `notes/agents-fs-store-backed-fs.md` — agents-store as
  the semantic-rich backing (datoms + PROV + meaning-links) vs this
  slot's flat `files(path, blob, meta)` slice. Decide `fs.store` vs
  widened `fs.sqlite` at card time.
