# koru-os → koru verification path: the asks (2026-10-21, koru-os @ 333b5ba)

What koru-os just landed, and what it needs from the koru `verify-path`
branch. koru-os authored the **consumer side** — a real corpus in the
committed-verdict shape, exercised in the wild. The emission and
re-decision legs are upstream.

## What koru-os now produces

- `<stem>.marks` — every solver verdict minted through the upstream
  command-marks channel (`emitter_helpers.commitCommandMark`, flushed by
  the backend after dispatch; `command_exit_code` is honored *after* the
  flush, so refused runs still land their corpus). Line shape:
  `@witness("kind","site","arm<-mechanism","verdict","payload")`.
  - `admission` — demanded iface bound / refused / waived (std-pure), incl.
    the always-on `koru.runtime` row. Payload carries `row=<iface>`,
    `declared_by=<row prov>`, `bind_by=<bind prov>`, `grade=<V|M|C|D>`,
    `reason=<tag>`.
  - `declaration` — malformed `koruos/realize:row` refusals (duplicate arm,
    contradiction vs earlier decl, missing field, bad JSON), site = the
    declaring module/program.
- `rows.json` (matrix mode) — the resolved row catalog as data;
  `scripts/check-realize.sh` recounts coverage from it and compares against
  the printed `arm-matrix.txt` — the projection is re-decided by an
  independent path, not trusted.
- `Binding.declared_by` — bind-level provenance (a program-supplied or
  provider-supplied bind on a builtin row reports `bind_by=koruos.native`,
  not `declared_by=builtin`).
- Measured probe: `~std/witness:enforce` on `boot_silo` compiles and the
  `witness` command reports `|c=7 |c[verified]=0 enforce=1` — the verified
  lane is seeded in the census, nothing mints those verdicts yet.

## Design constraint the corpus already exercises

**Kinds are decidable relations, never domain nouns.** One `admission`
kind serves every interface — silo, ext2, runtime, missing rows — because
the domain (iface, arm, mechanism, provenance, evidence grade) is payload
data. Checkers implement relations; domains are unauthorable data in the
mark. The koru-os corpus is the worked example of this factorization.

## Asks for the verification session (koru:ccomp / verify-path)

1. ~~**Commands as witness producers.**~~ **LANDED upstream.** Commands
   mint marks via `commitCommandMark(al, kind, site, arrow, verdict,
   payload)` — wire invariants (non-empty, no `"`/CR/LF) are validated at
   commit, the backend flushes `<stem>.marks` after dispatch, and
   `command_exit_code` is applied *after* the flush so a refused run
   still commits its verdicts. `realize` rides it now; measured marks
   for bound/refused/waived and declaration refusals. **Measured 10/10
   in `check-realize.sh`.** Open follow-up inside this ask: whether
   `WitnessCheck.lean` can re-decide the command-minted lines yet (ask 2).
2. ~~**Checker-side relations for `admission` / `declaration`.**~~
   **LANDED upstream (working tree).** `WitnessCheck.lean` grew a
   `@witness` mark parser, `ruleAdmission`/`ruleDeclaration` rulings
   (the verdict is FORCED by the committed payload's evidence shape —
   the catalog stays solver-side), the `admission_bound_mechanism`
   theorem, corpus-level `admissionCheck` (one verdict per (site,arm),
   one arm per `.marks` file — splice detection), and `witness_gate.sh`
   consumes golden/forged/drift marks corpora. Caught in the wild and
   fixed: `row=` names the serving row's declared iface, so tor-scoped
   demands (`site=koruos.silo:open` ← `row=koruos/silo`) need a
   `rowServesSite` correspondence — module row or tor-prefix row —
   landed with pins. Measured: every tor-scoped silo/spawn mark from
   real runs re-decides (12+14 lines, 0 bad).
3. **`|c[verified]` minting.** The census counts it; nothing produces it.
   Proc-level contract checks (`requires`/`preserves`/`obliges` over user
   procs) are decidable because koru-os's vocabularies are finite —
   typestate transitions, bag membership, effect sets. This is the
   "restricted congruent fragment" where proc witnesses pay.
4. **Path B adjacency.** The doc's "Use B" (koru-transform congruence) is
   open because the emitter doesn't expose pre/post IR — what landed is
   accounting-level (`transform-app` lines, `contract:preserves`/`obliges`).
   koru-os's projection problem is the same shape at gate level: emitted
   artifacts (manifest, matrix, Kraftfile) are transforms of committed
   data, and today they're re-decided by `check-realize.sh` recounting
   `rows.json` — a hand-rolled instance of the same re-decision the
   transform-oblige channel wants to own. If transforms expose
   pre/post-consumable surfaces, realize's artifact emission is a
   ready-made consumer.
5. **`[flow-eval]` emission** (doc's named hole): koruc doesn't emit
   flow-eval claims; the semantics kernel consumes hand-authored corpora.
   realize's `<stem>.marks` showed the pattern end-to-end — a solver
   minted its verdict corpus the day the channel opened; the ask is the
   emission leg for flow-eval, in the same shape.

## Relation inventory (what the vocabulary still lacks)

Beyond `admission`/`declaration`, the relations that pay for this corpus:

- **`congruence`** — equivalence between realizations (the `d<-s` arrow is
  already a correspondence slot). K1 byte-diff is empirical congruence,
  Alive2 is directional refinement, ISAR's OperEq/NF-agreement is the
  formal version. Every arm binding *is* a claimed congruence — "silo on
  unikraft ≡ silo on koru-native" — currently evidence-graded prose.
- **`derivation`** — emitted artifacts are lawful projections of committed
  data. `check-realize.sh` recounting `rows.json` is the hand-rolled
  instance; the transform-oblige channel is its proper owner.
- **`bound`** — measured resource claims (stack demand ≤ declared; the
  stack-demand.py shape is a `bound` verdict, not an admission).

And a structural note: `grade` stays **payload, not kind** — but its
alphabet (what V/M/C/D assert) should be pinned upstream so every corpus
means the same thing by "M". That unlocks decidable boot policy:
"admitted set requires grade ∈ {V,M}" is a gate over marks.

## ISAR correspondence (the same object at another altitude)

| koru-os | isar-proofs |
|---|---|
| arm binding (`iface -> mechanism`) | QuotientMap — an interface quotiented onto platform primitives |
| realize admission (bind iff row serves arm) | `try_adopt` — adopt iff a known map OperEq-matches on every probe; ISAR's is probe-sampled, realize's is declaration-checked — same gate, different evidence |
| `check-realize` recounting `rows.json` | witnesses comparing NF-for-NF / byte-for-byte |
| stack/resources as declared cost | `host/benches` measures feed selection while `battery` obligations gate |
| V/M/C/D evidence grades | same intent-fidelity annotation — which ground a claim rests on |

The ordering constraint that falls out of Taelin's clause and applies to
both: **cost-based provider selection is only lawful among proven-equivalent
alternatives.** Equivalence relation first, measured-best second —
otherwise "fastest" selects between things that aren't the same
computation.

## Honest bounds

- Today all of the above is **M-class**: measured, gated, reproducible —
  not machine-checked. `check-realize.sh` (9/9) is the gate; the Lean
  re-decision is the upgrade.
- Nothing in koru-os authors mark *vocabulary* — kinds stay checker-pinned
  upstream. koru-os only shapes the corpus and proves the factorization
  suffices (admission + declaration cover the whole verdict surface).
- The intent→proposition edge stays human: the row's `evidence:` field and
  the grade stamped on each mark are where that uncheckable edge is made
  legible, not hidden.
