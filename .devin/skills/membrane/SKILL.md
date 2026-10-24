---
name: membrane
description: Tend koru-os's durable-belief corpus — concepts/frag-*.md whose lineage lives in git-log trailers. Fire when recording or repudiating a durable belief (contract rulings, oracle lessons, axis decisions), or tracing a belief's history. NOT for build logs, task notes, or anything a gate row already proves.
---

# membrane — koru-os's durable beliefs, versioned by git

One durable belief = one file `concepts/frag-<id>.md`, frontmatter
`type/id/provenance/ts` (`id` == filename stem), prose body. The commit-msg
hook enforces the lineage: stage a concept and the commit must declare
`Action: create|evolve|merge|split|correct|move` + `Concept:` — or the whole
commit says `Evolution: acknowledged-none`.

## What belongs here (and what does not)

This corpus holds the beliefs **no gate row can state**: contract rulings
(damage is bidirectional; a surface is buffer+commit+lifetime), oracle
lessons (QEMU `-kernel` is PVH; the bag is an NR-bitmask, not an fd-grant),
axis decisions (SAS silos; provider personalities; X11 before Wayland), and
repudiations — the record of having been wrong.

It does NOT hold: build output, gate results (the `## Gates` rows in the log
are that ledger), task tracking (the todo/PLAN.md carries it), or prose that
duplicates running code. A belief that can live in a gate row should —
gardening is bidirectional: beliefs graduate OUT into walls and checks,
leaving only a pointer.

## The moves

- **create** — a new belief the repo didn't hold. `Action: create` +
  `Concept: frag-<id>`.
- **evolve** — the belief refined; prior body stays in history. The hook
  scaffolds `Occludes:` (the HEAD blob) when there's one staged concept.
- **correct** — the prior was *never right*. `Severs:` the repudiated blob +
  `Reason:` why it was wrong, and a `Signal:` — correction is intrinsically
  attention-worthy (the gate refuses `acknowledged-none` here).
- **merge/split** — `Parents:` ≥2 ids.
- **move** — custody changed, content did not (the hook verifies blobs
  match). Beliefs are never deleted.

History is append-only: no amend/rebase/force-push of landed commits.
Corrections are forward commits.

## Signals

`## World Model` declares `Signal: <type>` per commit, or
`Signals: acknowledged-none`. Interface files live in `signals/<name>.signal`
(`membrane: true` marks belief-class — declaring one *requires* a staged
concept in the same commit). koru-os's seeded vocabulary:

| signal | membrane | meaning |
|---|---|---|
| `contradiction` | yes | a held belief flipped on new evidence |
| `correction` | yes | a prior belief was never right |
| `regime-change` | yes | the rules of the game changed (a wall, a topology, a discipline) |
| `oracle-lesson` | yes | a provider/compositor oracle taught the contract something |

Declare a new signal name and its `.signal` file is minted as an orphan
(refine it later); near-misses of existing names refuse, so typos can't
fork the ontology.

## Commit layout

```
<subject>

<body>

## World Model
Signal: oracle-lesson — <what the provider taught>

## Gates            (required when koru/ or scripts/build-* is staged)
boot: 21/21
hosted: 27/27

## Membrane
Action: create
Concept: frag-<id>

Generated with [Devin](https://devin.ai)
Co-Authored-By: Devin <...>
```

Query the trajectory: `git log --grep="Signal: oracle-lesson"`,
`git log --grep="Concept: frag-<id>"`, `tail .git/signal-cards.jsonl`.
