# Handoff → koru verification-path session (from koru-os @ 522c07d)

Self-contained: assumes koru internals knowledge, no koru-os context.

## The one-paragraph context

`koru-os` (`C:\Users\fabi0\repos\koru-os`) is a Koru platform namespace:
`koru/*/index.kz` lifts declare identity-bound interfaces; `koru/realize`
is a `[command]` `|zig` proc that is a **solver** — it walks module and
program-level `koruos/realize:row { json }` declarations (the
`std/invariants` idiom: `[comptime|norun]` tors carrying JSON blocks,
harvested from `module_decl.items` / `program.items` `.flow` nodes),
merges them into a row catalog, and for each demanded interface + arm
emits a verdict: **bound / refused / waived**. Unikraft is one arm of
four (`unikraft/qemu-x86_64`, `unikraft/linuxu-x86_64`, `hosted`,
`koru-native`); refusals name the missing axis.

## What it produces today

`koruc <prog>.k realize gen --arm <a>` writes `realize.txt` (human
report), `<stem>.marks` (**the corpus — minted through the upstream
command-marks channel**, `emitter_helpers.commitCommandMark`; the backend
flushes after dispatch and honors `command_exit_code` only *after* the
flush, so refused runs still commit their verdicts), plus
`manifest-<arm>.txt` or Kraftfile/Makefile.uk. `realize matrix` writes
`arm-matrix.txt` + `rows.json` (resolved catalog as data — a re-decider
input).

`<stem>.marks` — every verdict in the upstream mark shape:

```
@witness("admission","koru.runtime","koru-native<-native-runtime","bound","row=koru.runtime declared_by=builtin bind_by=koruos.native grade=V")
@witness("admission","std.io:print","koru-native<-native-runtime","bound","row=std.io:print declared_by=builtin bind_by=koruos.native grade=V")
@witness("admission","koru.runtime","koru-native<-none","refused","reason=missing-binding")
@witness("declaration","rzfix.badrow","decl<-parsed","refused","binds-0-lacks-arm-or-mechanism")
```

**Relations used — two suffice for the whole verdict surface:**
`admission` (does the merged catalog admit this demand on this arm) and
`declaration` (is a declared row well-formed). The domain is payload:
iface, arm, mechanism, `row=` provenance, `declared_by=` (row),
`bind_by=` (bind — separate because a program/provider can bind a row it
does not own), `grade=` (evidence class V/M/C/D), `reason=` tag.

## The asks (upstream legs)

1. ~~**Commands as witness producers.**~~ **LANDED** — `commitCommandMark`
   validates wire invariants at commit, `flushCommandMarks` writes
   `<stem>.marks`, `command_exit_code` lets a refused run commit before
   exiting. `realize` rides it (measured 10/10 `check-realize.sh`).
2. **Checker-side relations.** `admission` = re-run the row-match over the
   committed payload; `declaration` = re-parse/refuse by the same rules.
   Vocabulary stays finite and checker-pinned; koru-os proves the
   factorization suffices (two kinds cover every verdict).
3. **`|c[verified]` minting.** The census counts `c_verified`; nothing
   produces it. Proc-level `requires`/`preserves`/`obliges` over finite
   vocabularies (typestate, bag membership, effect sets) is the decidable
   fragment where proc witnesses pay. Measured on `boot_silo`:
   `|c=7 |c[verified]=0 enforce=1`.
4. **Path B adjacency.** Transform congruence (Use B) stayed
   accounting-level pending pre/post IR exposure. koru-os's artifact
   emission is the same shape at gate level — manifests/matrix as
   re-decidable transforms — a ready-made consumer if that surface opens.
5. **`[flow-eval]` emission** — same hole, same ask: the kernel consumes
   hand-authored corpora; realize's marks are that pattern waiting for
   the emission leg.

## Still-missing relations (named, not yet exercised)

- **`congruence`** — equivalence between realizations; the `d<-s` arrow
  is already a correspondence slot. K1 byte-diff = empirical congruence,
  Alive2 = directional refinement, ISAR OperEq/NF = formal. Every arm
  binding is a claimed congruence ("silo on unikraft ≡ silo on
  koru-native"), today evidence-graded prose.
- **`derivation`** — artifacts as lawful projections of committed data.
  `scripts/check-realize.sh` recounting the matrix from `rows.json` is
  the hand-rolled instance.
- **`bound`** — measured resource claims (stack demand ≤ declared).

## Grade alphabet: upstream pins, consumers assign

`grade` stays **payload, not kind** — but the V/M/C/D meanings belong in
the verification branch so every corpus means the same by "M". Payoff is
decidable policy: *admitted set requires grade ∈ {V,M}* is a boot gate
over marks. koru-os uses: V = verified at pinned SHA, M = measured on
the box (log cited), C = carried-over claim, D = design only (README).

## ISAR correspondence (same object, other altitude)

| koru-os | isar-proofs |
|---|---|
| arm binding (`iface -> mechanism`) | QuotientMap — interface quotiented onto platform primitives |
| realize admission | `try_adopt` — adopt iff a known map OperEq-matches on probes; declaration-checked vs probe-sampled, same gate |
| matrix recount vs rows.json | NF-for-NF / byte-for-byte witnesses |
| stack/resources declared cost | `host/benches` measures feed selection, `battery` gates |
| V/M/C/D grades | intent-fidelity annotation |

Ordering law both obey: cost-based selection is only lawful among
proven-equivalent alternatives — equivalence first, measured-best second.

## Repo facts

- koru-os repo: `C:\Users\fabi0\repos\koru-os` (github Cypoe/koru-os,
  commit `522c07d`). koru: `W:\src\koru` (koruc at `zig-out/bin/koruc.exe`;
  zig must be on PATH: `/w/tools/zig-0.15.1`).
- Emit sites: `koru/realize/index.kz` — builtin rows ~L92, decl scanner
  ~L132-360, verdict marks ~L505-630, marks file ~L706.
- Checks: `bash scripts/check-realize.sh` — 9/9 (controls bind,
  negatives refuse by name in both text + marks surfaces, native provider
  opt-in, matrix recount).
- Fixtures: `koru/realize/tests/` (`control_rowed`, `negative_unrowed`,
  `negative_contradict`, `negative_badrow` + `badrow|unrowed` module dirs;
  `{{ ENTRY }}` template = fixture dir path).
- Native provider: `koru/native/{index.kz,runtime.zig}` — freestanding
  `posix_memalign`/`free` + `fputs`/`stdout`/`stderr`→COM1.
- Design contract: `docs/design/DESIGN-0001-execution-contract.md` §11.1.
