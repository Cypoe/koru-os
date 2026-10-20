# AGENTS.md — koru-os

Platform namespace for Koru. `koru/*/index.kz` lifts declare identity-bound
interfaces; `koru/realize` is the resolver command that binds them to an arm
or refuses loudly. Unikraft is one arm, not the OS. Design contract:
`docs/design/DESIGN-0001-execution-contract.md`.

## Toolchain (Windows box)

- koruc: `W:\src\koru\zig-out\bin\koruc.exe` (source: `W:\src\koru`)
- zig: `W:\tools\zig-0.15.1` — must be on `PATH` (POSIX form
  `/w/tools/zig-0.15.1`) or koruc crashes `FileNotFound` spawning the
  backend build. From Git Bash: `PATH="/w/tools/zig-0.15.1:$PATH" koruc ...`
- koru-libs modules (e.g. `unikraft/sched`): `W:\src\koru-libs`

## The realize command (the instrument)

```bash
koruc <prog>.k realize gen --arm <arm>   # writes realize.txt + Kraftfile/Makefile.uk
koruc <prog>.k realize gen --arm hosted       # or koru-native -> manifest-<arm>.txt
koruc <prog>.k realize matrix                # -> arm-matrix.txt: row catalog x 4 arms
```

Artifacts land in the *working directory* — run fixture programs from a
scratch dir, not the repo root, or generated files dirty `git status`.

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

Fixtures live in `koru/*/tests/*.k` and use `{{ ENTRY }}` templating
(substitute the fixture dir's absolute path before running — they are not
runnable verbatim). Controls/negatives in `koru/realize/tests/`:
`control_rowed.k`, `negative_unrowed.k`, `negative_contradict.k`,
`negative_badrow.k`. A refusal naming module + missing field is a PASS for a
negative; never weaken a fixture to go green.

Boot programs (`boot_ext2`, `boot_nid`, `boot_slice`, `boot_spawn`,
`boot_silo`) double as the demand side of `notes/arm-gap-enumeration.md` —
run `--arm koru-native` on them to re-measure the native gap after landing
providers.

## Before pushing

```bash
bash scripts/check-realize.sh   # 6 checks: controls bind, negatives refuse
                                # by name, koru-native binds iff imported
```

Green means the declaration contract still says what the fixtures pin. A
fail after an intentional semantics change means the fixture's comment and
the expected line get updated together — never the check dropped.

## Conventions

- Evidence classes V/M/C/D per README. `blocker` / `not a blocker` /
  `unmeasured` when reporting toolchain state — claims get re-measured.
- Refusals are the spec's loud axis, not bugs. A malformed row declaration
  must refuse naming module/file/line, never a silent skip.
- Provider artifacts ride in `deltas` (e.g. `src:koru/native/runtime.zig`);
  mechanisms are names (`kconfig`, `host-libc`, `native-runtime`).
- `git push` after meaningful commits (see BLOCKERS B4).
