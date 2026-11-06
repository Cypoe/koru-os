---
type: belief
id: frag-posix-is-a-provider-not-a-store
provenance: Fabian ruling in session — agents-fs lane fold-in, 2026-11-06
ts: 2026-11-06
tags: [fs, posix, store, agents-store, agents-fs, doctrine, lane]
---

**POSIX is a personality, never the substrate.** The filesystem lane
has one shape across three independent discoveries — WinFS (files as
relational items), Ross RTN (surface vs. deep structure), and
agents-store (datoms + minted IDs + PROV lineage + default-deny) —
and the ruling that falls out of it:

- The *store* owns truth: identity, attributes, history, meaning.
  Paths are serializations of entity tuples (standing doctrine,
  `relational-filesystem` in user memory).
- Every filesystem — ProjFS, FUSE, `ChildFsOps`, 9P, virtiofs — is a
  *provider* rendering that store. None owns it; swapping providers
  changes nothing canonical.
- Meaning-links (session, intent, provenance, supersedes) are datoms,
  materialized sidecar-free as generated directory views. That is the
  Ross layer and the honest face of DESIGN-0001 §9's clear-text
  associative rung.
- agents-fs starts as an **adapter inside agents-store** and graduates
  to its own repo only when it serves a wire (9P server, FUSE daemon,
  provider registration). Adapter-first is Fabian's explicit ruling,
  "eventually that's agents-fs though" — graduation is deferred, not
  denied.

Falsifier: if a provider ever needs to *write* store truth that isn't
expressible as datoms+certificates, the boundary leaked — the provider
became a second store. Open: whether `fs.store` binds over 9P with
sideband metadata (violates sidecar-free) or waits for an in-corun
datom engine; xattr parity vs. loud refusal; whether the semantic
view layer belongs to agents-fs or agents-store's mediator tier.
