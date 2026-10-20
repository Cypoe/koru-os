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

**The deferred `~decl`/facet question now has three consumers' evidence.**
The `catalog` mark is a declaration committed as data — typed fields
(iface, declared_by, binds), provenance, dedup (one mark per merged row),
deferral (binds=none still counts in total) — read by three independent
consumers: the realize producer, the `rows.json` recount, and the Lean
checker. Whatever `~decl` becomes upstream should be shaped by *this*
corpus's requirements, not by syntax first.

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
3. **`|c[verified]` minting — decision-blocked, not work-blocked.**
   Per the verification session: `|c[verified]` is a *parked ruling*
   (`koru-c-lane-test-plan.md` — "parked, not repudiated… come back only
   if measured refusal rates prove the wall costs too much") and the
   `requires` annotation surface is Lars's ledger item. Minting the tag
   un-parks a ruling — his call. The koru-os-side evidence stays ready:
   proc-level `requires`/`preserves`/`obliges` over finite vocabularies
   (typestate, bag membership, effect sets) is the decidable fragment
   where proc witnesses pay.
4. **Path B adjacency — now with a landed instance.** The doc's "Use B"
   (koru-transform congruence) stays open at the IR level, but the same
   shape is now *measured* at gate level: `realize matrix` commits
   `catalog` marks (the resolved rows as data) + `projection` marks
   (one `bound=<n> total=<m>` cell per arm), and `projectionCheck` in
   `WitnessCheck.lean` recounts each cell over the committed catalog —
   `koru-native: 2/8` is a derived, Lean-re-decided claim, not printed
   prose. `check-realize.sh` runs the Lean re-decision in-gate
   (missing toolchain = failure). This is the consumer pattern
   transform-oblige wants when pre/post IR surfaces exist: commit the
   transform's input as marks, commit the derived claim, recount.
5. ~~**`[flow-eval]` emission**~~ — **already existed upstream.**
   `comptime_eval.zig` emits flow-eval claims on the enforce path,
   `FlowCheck` re-decides them, `310_141` pins it (`semantics gate:
   PASS`). No leg needed.

## Relation inventory (what the vocabulary still lacks)

Beyond `admission`/`declaration`, the relations that pay for this corpus:

- **`congruence`** — equivalence between realizations (the `d<-s` arrow is
  already a correspondence slot). K1 byte-diff is empirical congruence,
  Alive2 is directional refinement, ISAR's OperEq/NF-agreement is the
  formal version. Every arm binding *is* a claimed congruence — "silo on
  unikraft ≡ silo on koru-native" — currently evidence-graded prose.
- **`derivation`** — emitted artifacts are lawful projections of committed
  data. **Landed for the matrix**: `catalog`+`projection` marks +
  `projectionCheck` recount in the checker. Still open for the manifest
  and Kraftfile projections (same pattern, same owner).
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

- `check-realize.sh` (12/12) is the gate — including the Lean
  re-decision of admission/declaration marks and the matrix recount.
  The remaining M→V upgrade is checker-side depth: today it re-decides
  evidence *shape* and *corpus laws* (the catalog stays solver-side);
  committing the catalog digest or the catalog itself is how a checker
  could re-run the match proper.
- Nothing in koru-os authors mark *vocabulary* — kinds stay checker-pinned
  upstream. koru-os only shapes the corpus and proves the factorization
  suffices (admission + declaration cover the verdict surface;
  catalog + projection cover the matrix).
- The intent→proposition edge stays human: the row's `evidence:` field and
  the grade stamped on each mark are where that uncheckable edge is made
  legible, not hidden.
