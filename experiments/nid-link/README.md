# Build-time resolution: realize table 3 refuses before an image exists (DESIGN-0001 §11.7)

`koruc <boot.k> realize gen` evaluates the `koruos/nid` binding chain while building:

- the export table comes from the module's own host lines, the same lines that are compiled
  into the image;
- every literal `open` manifest is admitted with the lift's rules;
- every literal `resolve` / `probe` is resolved against its lexically enclosing table, and a
  `retarget` is applied on its `ok` arm.

`resolve` is a **required** import: if it cannot bind, `realize.txt` table 3 gets a
`phase=configure` refusal and no Kraftfile is written, so `kraft build` has nothing to
build. `probe` is **optional**: its unbound outcome is predicted, and the run-time refusal
remains a branch the program handles.

## Result: PASS (checks frozen in `5ad7948`, 19:23:41 CEST; counted 19:23:52–19:27:24, TCG)

| id | result | evidence |
|----|--------|----------|
| L1 | 16 predictions = 16 run-time outcomes, in order, field for field, 3/3 | `evidence/run-*-agree.txt`, `evidence/realize.txt` |
| L2 | 4 required-import refusals with no Kraftfile and no `.unikraft`: no row, wrong version (offers `c/libc/1/fputs`), refused table, 4-bit collision; satisfied `resolve` and unbound `probe` accepted | `evidence/build-gates.txt` |
| L3 | NID N1–N10 3/3 on the new image (`d6ab5c53…`, 209,584 B); R2/R3 PASS; stack bound 88,480 B ≤ 131,072 B; compile gates PASS | `evidence/run-*-nid.txt`, `config.txt`, `stack.txt`, `compile-gates.txt` |
| L4 | Slice A 3/3 and DS0 3/3; realize R1–R6 PASS | `evidence/regress-realize.txt` |

Mutation check of `agree.py`: changing the run-time retarget count in a copy of the run-1 log
fails L1 (`evidence/agree-mutation.txt`).

## Limits (honest)

- **Literals only.** Only literal manifests and foreign names are evaluated. A required
  `resolve` with a non-literal name is refused at build time ("use probe"). A non-literal
  manifest is reported as "run-time admission only", and a required `resolve` under it is
  refused.
- **Table scope is lexical.** The table is the nearest enclosing `open`'s `ok` arm. Tables
  passed across flows or stored are not tracked.
- **Rules are implemented twice.** The admission rules exist twice: in the lift (run time)
  and in `koru/realize` (build time). L1 is the measurement that they agree. Sharing one
  implementation waits on a common module home (Q33).
- **Run-time-only facts stay run-time.** Generations and stale bindings are not predicted;
  the lift still refuses them at run time.
- **Agreement is checked only on the executed path.** This image runs every arm that holds
  a prediction. Arms that only print FAIL hold no `resolve`.

## Reproduce

```
PATH=/workspace/tc/koru/zig-out/bin:/workspace/tc/zig-x86_64-linux-0.15.2:/workspace/tc/kraft:$PATH
../nid/build-nid.sh <koru-libs @ ff5cb559> <workdir>
../nid/run-nid.sh <workdir>/koruos/nid/tests/.unikraft/build/koru_qemu-x86_64 <rundir>
./agree.py <workdir>/koruos/nid/tests/realize.txt <rundir>/serial.log
./check-build.sh <koru-libs> <scratch>
```

Concordance: `resolve`, `probe`, `required import` and `optional lookup` follow the proposed
rows of DESIGN-0001 §2.2. They are not registered in the ccomp matrix (`Cypoe/koru` `ccomp`
`docs/concordance-matrix.md` @ `b39a442f`) until Fabian approves the six terms from §11.6.
`probe` is a seventh term that is proposed only.
