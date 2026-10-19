# Slice A: contract, supervisor and a detachable view in one Koru image

DESIGN-0001 §11.4. The lift is `koru/slice/index.kz` (module `koruos/slice`); the program is
`koru/slice/tests/boot_slice.k`. The acceptance criteria are in `ACCEPTANCE.md`, frozen before
the counted runs.

Build and run (TCG only):

```
PATH=/workspace/tc/koru/zig-out/bin:/workspace/tc/zig-x86_64-linux-0.15.2:/workspace/tc/kraft:$PATH
./build-slice.sh <koru-libs @ ff5cb559> <workdir>
./check-negatives.sh <workdir> > gates.txt
./run-slice.py <workdir>/koruos/slice/tests/.unikraft/build/koru_qemu-x86_64 <rundir>
./check.py <rundir> <workdir>/koruos/slice/artifacts.txt gates.txt
```

Concordance: the new terms used here (`spawn`-shaped child record, `grant`, `rights bag`,
`seal`, `reap`, `abandon`, `realization`, `interface descriptor`) are to be registered against
the ccomp matrix, `Cypoe/koru` branch `ccomp`, `docs/concordance-matrix.md` (DESIGN-0001 §2.3).

## Result (2026-10-19, counted runs 18:48 CEST, TCG)

**Slice A passes 3 of 3 runs as frozen** (S9–S14 and x). The kernel sha256 is `7a0c1501…`
(197,504 B), built from `88516f4` (`evidence/kernel.txt`).

| run | S9 | S10 | S11 | S12 | S13 | S14 | x | view before detach / after reattach | gap | wall |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | PASS | PASS | PASS | PASS | PASS | PASS | PASS | last tick 10 / first tick 23, `held=8..23` | 3.50 s | 9.36 s |
| 2 | PASS | PASS | PASS | PASS | PASS | PASS | PASS | last tick 10 / first tick 23, `held=8..23` | 3.50 s | 9.39 s |
| 3 | PASS | PASS | PASS | PASS | PASS | PASS | PASS | last tick 10 / first tick 23, `held=8..23` | 3.50 s | 9.38 s |

What the evidence shows:

- **Imports and binding.** The program declares three versioned imports.
  - For each one, the loader passes over incompatible candidates by name and binds the
    authorized provider whose artifact is linked into this image.
  - Three manifests are refused before any child exists (revision/entry size; unauthorized;
    not linked / effects exceed import).
- **The task.** It runs 30 ticks through the providers it was granted:
  - the read-back after eviction is exact (entries 15..30);
  - the call counts are recorded per binding at release (store 47, clock 61, view 31).
- **The supervisor.** It refuses to seal a child with an empty bag, abandons it, and runs the
  real child through reserve → grant × 3 → seal → start (on evidence) → wait → reap. The roster
  goes 0 → 1 → 0.
- **The view.** It detaches for 3.5 s while the task goes from tick 10 to 23. The first frame
  after the reattach reconstructs the gap from the store (`held=8..23`). The child's identity
  stays `2.1` throughout.
- **Compile gates** (`evidence/compile-gates.txt`):
  - `start` before `seal`, `grant` after `seal` and `reap` while running are rejected with
    KORU030;
  - a running child that is never waited for is also rejected ("obligation <running!> was not
    discharged"), so a leaked child is a compile error here. The B5 auto-discharge did not apply.

**Void attempt.** A first attempt at 18:46 CEST is recorded in `evidence/void-attempt.txt` and is
not counted. A harness error (`/usr/bin/time` missing) made the gate step run against a missing
workdir. Its S9–S14 were PASS and x was FAIL. The checks were not changed for the re-run.

**Regression.** The DS0 image is 3/3 PASS with the same toolchain (`evidence/regress-ds0.txt`).
Slice A touches no Unikraft patch and no shared library, so M3–M9 are unaffected.

**Findings.**

- The kraft build is not byte-reproducible: two builds from the same commit gave different
  kernel hashes. The kernel sha identifies a kernel, not a commit.
- The guest cannot tell whether a view is attached, and that is by design (§7).
- Artifact identity is a source-block hash, not a hash of the linked bytes.
- The child runs on the supervisor's thread; the module owns the body.
