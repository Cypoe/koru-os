# agents-fs lane — store-backed filesystem, POSIX as provider

Status: D (design). Fold-in note, 2026-11-06. Nothing here is measured
against a running system; every claim carries its evidence class.

## The convergence

Three independent discoveries of the same shape:

- **WinFS** (Microsoft Research): files as items in a relational store
  with typed properties and links. Failed commercially on Vista timing,
  not design.
- **Douglas T. Ross RTN**: surface structure (what you see) vs. deep
  structure (what it *means* — plans, intents, provenance). The
  semantic net is the product; the filesystem is one rendering.
- **agents-store** (`C:\Users\fabi0\repos\agents-store`): datom entity
  store — minted IDs, append-only history, PROV lineage, default-deny
  writes, wrappers/mediators as projections. POC-frozen, 303 tests.
  The store half of WinFS already exists and is stricter than WinFS
  ever was.

Standing doctrine: `~/.agents/memory/concepts/relational-filesystem.md`
— "identity first, paths as projections", re-confirmed 2026-10-23 in
koru-os context. This note is the concrete lane that doctrine lands in.

## What already exists in this repo (V: read this session)

- `challenges/sqlite-fs-view` — open slot, `iface: koruos/fs.sqlite`,
  `ChildFsOps` provider over SQLite. Its own notes say: "the
  relational-filesystem doctrine is the long-form version — this slot
  is the minimal measurable slice."
- `challenges/fs-initramfs` — landed (M): cpio → RAM `ChildFsOps`,
  proof that a *view*, not a store, is the provider shape.
- DESIGN-0001 DoD-1 — "a real filesystem" is a definition-of-done row;
  `fs.*` is ~20 POSIX-verb interface rows binding to vfscore ops.
- DESIGN-0001 §9 — associative memory as a later rung, clear-text
  model first. The semantic layer below is that rung's navigable face.
- `koru-libs/unikraft/ninep` — 9P lift exists; DESIGN-0001 already
  rules it "a bridge, does not satisfy DoD-1" for the real FS.

## The stack

```
agents-store            datom truth: identity, attrs, PROV lineage,
                        default-deny writes          (exists, Python)
     │
agents-fs               semantic FS projection: paths are serializations
     │                  of entity tuples; meaning-links are datoms,
     │                  sidecar-free                    (adapter first)
     ├─ ProjFS           Windows userspace, files-on-demand (V: backlog)
     ├─ FUSE             Linux / PVS                     (V: backlog)
     ├─ ChildFsOps/9P    koru-os arm providers            (this repo)
     └─ virtiofs         host bridge, later               (D)
```

POSIX is the *personality*, never the substrate. Every provider above
renders the same store; none owns it.

## The semantic layer — the part that is actually new

A plain FS adapter yields bytes-at-paths (WinFS-lite, and sqlite-fs-view
is exactly that minimal slice). What makes it *agents*-fs is that every
item carries its edges — which session produced it, what it was for,
what it derives from, what it supersedes — already expressible as
datoms + PROV. Directory structure can be **generated from semantics**
rather than declared:

- `session/ses_<id>/` — everything a session touched
- `intent/<goal>/` — work grouped by purpose
- `supersedes/<old>→<new>` — lineage walks

Sidecar-free as far as possible (Fabian, 2026-11-06): meaning lives in
datoms; any on-disk rendering is a re-materializable projection, never
the record. This is Ross's surface/deep split made literal — and it is
the honest connection to DESIGN-0001 §9: the clear-text associative
rung *is* these edges; tensors are a later encoding of the same graph.

## Mapping onto the koru-os contract

- Candidate iface: `koruos/fs.store` (peer of `koruos/fs.sqlite`) —
  same `ChildFsOps` verb surface, different backing. Or widen
  `fs.sqlite`'s provider family; decide at card time, not here.
- POSIX verbs translate to datom queries. Honest limits to state
  in-code (inherited from sqlite-fs-view's notes): directory
  synthesis, hardlink = row alias vs inode, rename atomicity, fsync/
  flock translation, xattrs have no datom home yet.
- Writes go through the store's default-deny path — a FS provider is
  a *mediator client*, not a back door around certification. Every
  refusal is a `refusal` row with a reason.

## Boundary honesty — the gap that must be named

agents-store is Python stdlib + sqlite3. A koru-os `ChildFsOps`
provider cannot link it in-process. The bridge options, in order of
increasing honesty about cost:

1. **Host-side store + 9P/FUSE** — store runs on host, guest/consumer
   reaches it through the existing bridge lifts. Cheapest, already
   half-built (ninep), but the guest sees a *remote* FS, not the store.
2. **Store-as-a-service over a socket** — same shape, own protocol.
   Duplicates what 9P already standardizes; only if 9P's semantics
   can't carry datom metadata (likely — 9P has no typed-attr channel;
   meaning-links would ride as xattr-ish side channels = sidecars,
   which we ruled out).
3. **In-kernel/corun datom engine** — the real endgame, and the
   "POSIX as provider" literal reading: a unikernel arm whose FS *is*
   the store. Depends on the unikraft lift catalog and on
   cross-process identity ("resource bridge") — named upstream-open
   problem in agents-store's backlog.

Option 1 is the only one buildable this quarter; option 3 is the lane's
reason to exist. Option 2 is probably a trap — it re-invents 9P worse.

## Sequencing

1. **agents-store side (now)**: filesystem projection adapter —
   entities-with-body as files-on-demand. ProjFS on this Windows box,
   FUSE on PVS/Linux. Sidecar-free meaning-links materialized as
   generated directory views. This is agents-fs v0 and it needs no
   koru-os anything.
2. **koru-os side (this repo)**: promote `sqlite-fs-view`'s shape to a
   `fs.store` card once a real consumer exists — the honest trigger is
   a guest program that needs store semantics POSIX can't express
   (typed attrs, lineage queries), not novelty.
3. **agents-fs repo**: graduates from agents-store adapter to its own
   repo when it serves a wire (9P server, FUSE daemon, ProjFS
   provider registration) — not before. Adapter-first per Fabian's
   ruling 2026-11-06; "eventually that's agents-fs though."

## Open questions for Fabian

- Does `fs.store` bind agents-store over 9P-with-sideband-metadata
  (violates sidecar-free) or wait for option 3?
- xattrs: is there a datom attribute class for POSIX xattr parity, or
  do we declare xattrs unrepresentable and refuse loudly?
- Does the semantic view layer (session/intent/supersedes dirs) belong
  to agents-fs or to agents-store's mediator tier? Lean: mediator —
  it is a *rendered* view, and agents-store already owns render-path
  mediation.
