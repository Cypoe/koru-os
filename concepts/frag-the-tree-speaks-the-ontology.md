---
type: belief
id: frag-the-tree-speaks-the-ontology
provenance: koru-os repo reorganization, 2026-11
ts: 2026-11-05
tags: [layout, ontology, arms, upstream, rig]
---

**Directory names are part of the specification, not decoration.**
The 2026-11 reorg renamed three roots precisely because each old name
lied about what lived under it:

- `koru/` → `koruos/` — the directory is the mount root of the
  `koruos:` module namespace. When the folder name and the namespace
  it materializes disagree, the folder name is wrong. Every lift
  resolves `import koruos/x` → `koruos/x/index.kz`; the rename made
  the filesystem honest about the resolution it was already doing.
- `hosted/` → `rig/` — the old top-level dir was the hosted-arm
  *oracle rig* (vroot jail, Hyprland oracle, kvview), and its name
  collided with `koruos/hosted/` (hosted *provider lifts*). The rig
  is an instrument for measuring hosted behavior, not the hosted
  providers themselves; giving it a non-interface name keeps the
  two roles unmixable. Hosted is a realization path and an oracle,
  never the OS definition.
- `lib/` → `arms/unikraft/` — everything in `lib/` was
  *project-owned* Unikraft-arm C shims (elfloader, ext2vfs, kms,
  spawn+mmu). Calling it `lib/` implied vendored third-party, which
  hid the fact that we authored it. Arm material lives under
  `arms/<arm>/`.

The converse rule is now load-bearing: **`upstream/` holds only
third-party donors, materialized by `origins.lock`, always
gitignored.** Before the reorg, donor targets were scattered across
root names (`m3/`, `m7bin/`, `m9src/`, `tc/`) chosen by whichever
milestone fetched them — provenance lived in the lock but not in the
tree. Now every lock `target` is `upstream/<name>`: if a directory
isn't in `origins.lock`, nothing vendored may sit there, and nothing
project-owned may hide there either.

The durable rule: when a name stops describing the thing it contains,
rename the directory — a stale name is a belief the tree keeps
asserting after the code stopped believing it.
