# AGENTS.md — koru-os

Platform namespace for Koru. `koruos/*/index.kz` lifts declare identity-bound
interfaces; `koruos/realize` is the resolver command that binds them to an arm
or refuses loudly. Unikraft is one arm, not the OS. Design contract:
`docs/design/DESIGN-0001-execution-contract.md`.

## Toolchain (Windows box)

- koruc: **pinned** `W:\src\koru-aaa6457\zig-out\bin\koruc.exe` — a
  detached worktree at `aaa64576c` (the `iface:`-arg commit). The live
  checkout `W:\src\koru` is on `fork/ccomp`; there the zig emitter
  leaks `|c` proc bodies into zig output (`handler__c` raw C text) and
  every `std/io` consumer fails the backend build. Scripts take
  `KORUC=` override — restore the default once ccomp is fixed.
  Pin-local patch: `koru_std/bridge*.kz` `create`/`run`/`close`/
  `get-handles` carry `~[retain]` — the declared mechanism for tors
  invoked by name from generated host text (a compiled driver calls
  `run_event.handler`, which flow reachability cannot see). Upstream
  candidate; without it a REPL-style driver prunes the bridge.
- zig: `W:\tools\zig-0.15.1` — must be on `PATH` (POSIX form
  `/w/tools/zig-0.15.1`) or koruc crashes `FileNotFound` spawning the
  backend build. From Git Bash: `PATH="/w/tools/zig-0.15.1:$PATH" koruc ...`
  **Fold-bug caveat (measured 2026-10):** this zig/LLVM mis-optimizes
  bounded-int arithmetic in `native/user.zig`'s surface-blit loop —
  observed `cw*4` folded through `andl $0x7fc` (len=0 for cw=1024 →
  silent zero-blit) and a phantom `0x1ff` bound-check `ud2`. The
  workaround in-tree: `@setRuntimeSafety(false)` on the already-validated
  loop plus an empty `asm volatile` barrier making the byte count opaque
  to the folder. If a syscall loop produces zeros/short-copies with no
  error, disassemble the loop before trusting the source semantics.
- koru-libs modules (e.g. `unikraft/sched`): `W:\src\koru-libs`

## The realize command (the instrument)

```bash
koruc <prog>.k realize gen --arm <arm>   # writes realize.txt + Kraftfile/Makefile.uk
koruc <prog>.k realize gen --arm hosted       # or koru-native -> manifest-<arm>.txt
koruc <prog>.k realize matrix                # -> arm-matrix.txt: row catalog x 4 arms
```

Artifacts land in the *working directory* — run fixture programs from a
scratch dir, not the repo root, or generated files dirty `git status`.

`<stem>.marks` (gen mode) — the command marks channel — commits every solver
verdict in `@witness("relation","site","arm<-mechanism","verdict","payload")`
shape — `admission` for bind/refuse/waive, `declaration` for malformed rows —
with `declared_by`/`bind_by` provenance and the row's evidence grade. The
channel validates the wire invariants at commit and the compiler names the
artifact; `verify/witness/WitnessCheck.lean` re-decides both relations.
Matrix mode mints too: `catalog` marks (the resolved rows as data) and
`projection` marks (one `bound=<n> total=<m>` cell per arm) — the checker's
`projectionCheck` recounts every cell over the committed catalog, so an
`arm-matrix.txt` line like `koru-native: 2/8` is a derived, re-decidable
claim. `rows.json` (matrix mode) is the same catalog for non-Lean
consumers; `check-realize.sh` re-counts it independently AND runs the
Lean re-decision (missing toolchain = failure).

Known arms: `unikraft/qemu-x86_64`, `unikraft/linuxu-x86_64`, `hosted`,
`koru-native`. An arm with no binding for a demanded interface is a
`refused:` line — that is the provider gap speaking, not an error.

## Row declarations (DESIGN-0001 §11.1)

Each lift declares its own contract in `index.kz`:

```koru
~import koruos/realize
~koruos/realize:row {
    "iface": "koruos/silo",          // what the row serves; ":tor" suffix scopes to a verb
    "stack": 4096,
    "binds": [{ "arm": "...", "mechanism": "...", "deltas": [...] }]
}
```

- `iface` names the serving target — declaring site is *provenance*, not
  ownership; a program may bind a lift it does not own (native providers).
- Unset fields defer to an earlier declaration; set-and-different refuses;
  duplicate `(iface, arm)` refuses naming both provenances.
- `koruos/native` is the freestanding provider (`runtime.zig`:
  `posix_memalign`/`free` + `fputs`/`stdout`/`stderr` -> COM1). Opt-in:
  programs must `import koruos/native` to get native bindings.
- Host-line `const realize_row = .{ ... }` remains as fallback for modules
  that cannot import `koruos/realize`.

## Tests

Fixtures live in `koruos/*/tests/*.k` and use `{{ ENTRY }}` templating
(substitute the fixture dir's absolute path before running — they are not
runnable verbatim). Controls/negatives in `koruos/realize/tests/`:
`control_rowed.k`, `negative_unrowed.k`, `negative_contradict.k`,
`negative_badrow.k`. A refusal naming module + missing field is a PASS for a
negative; never weaken a fixture to go green.

Boot programs (`boot_ext2`, `boot_nid`, `boot_slice`, `boot_spawn`,
`boot_silo`) double as the demand side of `notes/arm-gap-enumeration.md` —
run `--arm koru-native` on them to re-measure the native gap after landing
providers.

## Before pushing

```bash
bash scripts/check-realize.sh   # declaration tier: controls bind, negatives
                                # refuse by name, matrix marks re-decided Lean-side
bash scripts/check-boot.sh      # boot tier: build-native.sh + QEMU -kernel,
                                # asserts the fixture's own serial output
```

Green on realize means the declaration contract still says what the
fixtures pin; green on boot means an emitted program actually ran on the
image — the two tiers are deliberately separate (a bound row is not a
booted program). A fail after an intentional semantics change means the
fixture's comment and the expected line get updated together — never the
check dropped.

`scripts/build-native.sh prog.k out.elf` emits via koruc then links
`native/boot.zig` (multiboot2 + PVH note, 32→64 trampoline, SSE enable) +
`native/runtime.zig` + the emitted program into a flat 1 MiB ELF — boot it
with `qemu-system-x86_64 -kernel out.elf -serial stdio -display none`.

## Conventions

- Evidence classes V/M/C/D per README. `blocker` / `not a blocker` /
  `unmeasured` when reporting toolchain state — claims get re-measured.
- Refusals are the spec's loud axis, not bugs. A malformed row declaration
  must refuse naming module/file/line, never a silent skip.
- Provider artifacts ride in `deltas` (e.g. `src:koruos/native/runtime.zig`);
  mechanisms are names (`kconfig`, `host-libc`, `native-runtime`).
- `git push` after meaningful commits (see BLOCKERS B4).

## Commit discipline (installed via `hooks/install.sh`)

Every authored commit answers three sectioned questions — silence is a
refusal, the honest opt-outs are explicit:

- `## World Model` — `Signal: <type> — <note>` per belief that changed, or
  `Signals: acknowledged-none`. Signal interfaces live in `signals/*.signal`
  (register-on-miss; `membrane: true` marks belief-class → a staged
  `concepts/` file is required in the same commit).
- `## Gates` — REQUIRED when staging `koruos/` or `scripts/build-*`:
  `name: pass/total` rows of measured evidence, or `deferred — <reason>`.
  "Gates green" is a measured claim, not prose.
- `## Membrane` — durable beliefs live in `concepts/frag-<id>.md`
  (frontmatter `type/id/provenance/ts`, id == stem). Stage one → declare
  `Action: create|evolve|merge|split|correct|move` + `Concept:` (every staged
  frag named); stage none → `Evolution: acknowledged-none`.

pre-commit runs `scripts/git_wall.sh --staged` (.gitignore is the oracle;
allowlist does not widen). post-commit appends Signal cards to
`.git/signal-cards.jsonl` (untracked telemetry). Full doctrine:
`.devin/skills/membrane/SKILL.md`. Never `--no-verify` except a recorded
emergency; merge commits are exempt (topology, not authorship).
