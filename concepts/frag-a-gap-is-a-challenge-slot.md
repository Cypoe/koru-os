---
type: belief
id: frag-a-gap-is-a-challenge-slot
provenance: koru-os challenges/ ledger, 2026-11 — format adapted from koru-desktop/providers
ts: 2026-11-05
tags: [challenges, process, gaps, catalog, board]
---

**Open work is a set of challenge slots bound to seams, not a prose
list that drifts.** `challenges/<name>/entry.md` carries the contract
as frontmatter — `iface` (the seam it binds), `arms`, `lane`
(how it may be solved: native-zig / koru-lift / donor-c / hosted /
oracle), `needs` (slot dependencies, verified), `tier` (qemu | hw),
`status`, `evidence` — plus a falsifiable `## Acceptance` body.
`accept.sh` is the minimal runnable probe: landed slots re-run their
evidence, open slots print criteria and exit 77 (skip).

Two disciplines keep the ledger honest:

- **The catalog is generated, never edited.** `challenges/CATALOG.md`
  is emitted by `scripts/board.sh` from the entries; `--check`
  verifies freshness and metadata (name == dir, lanes/status/tier
  vocab, needs resolve, landed ⇒ evidence class V/M/C/D). A prose
  table edited by hand rots within two commits.
- **accept.sh is a probe, not the suite.** The boot-gate rows in
  `check-boot.sh` remain the authoritative measured evidence; a slot
  lands by flipping status + evidence and giving accept.sh a real
  reproduction — not by the gate losing a row.

The format is deliberately license-aware (`provenance:` notes, AGPL
donors marked read-only) because slots invite ports, and a port that
silently ingests a copyleft kernel is a belief hazard, not a gap
closure. Peer slots in koru-desktop's provider catalog are named in
`peer:` — their unikernel-tier facts transfer; the provider itself
is ours, because our providers bind seams their build never sees.
