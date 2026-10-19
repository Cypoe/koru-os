# Dissected Spawn: first measured skeleton (`koruos/spawn`)

DESIGN-0001 §8.6. The lift is `koru/spawn/index.kz`. It has koru-libs shape and lives in
koru-os for now; nothing is pushed to `Cypoe/koru-libs` (Q33). The acceptance in
`ACCEPTANCE.md` was frozen in `8dae7ec` (2026-10-19 19:33:14 CEST) before the counted runs.

## Result (2026-10-19 19:33–19:37 CEST, M under QEMU TCG)

- **Build:** `realize gen` derives the Kraftfile with the new `koruos.spawn` row. R2/R3 PASS.
  The stack FITS at 77,192 B ≤ 131,072 B (order 5).
- **Compile gates:** SPAWN-compile PASS. Both controls compile. `start` on staged, `grant`
  after `seal`, `reap` on running, and a leaked running child are KORU030.
- **Boots:** S1–S11 and R pass in 3/3 boots of one image (`evidence/run-{1,2,3}.txt`,
  `run-*-serial.log`, sha256 in each run file).
- **Checker mutation:** in a copy of the run-1 log, an extra `sees fd/1` line for the empty
  child and a changed over-grant reason make S1 and S3 FAIL (`evidence/check-mutation.txt`).
- **Regressions:** 19:34–19:37 CEST (`evidence/regressions.txt`). Slice A S14 and DS0 pass 3/3,
  R6 PASS. The NID image passes N1–N10 and L1 3/3.

## What the skeleton shows

- **Rights are empty by default.** A child holds only the ambient set (memory ≤ budget,
  clock, exit, yield).
- **Rights are added only by attenuating grants.** A grant of a handle the parent does not
  hold, an over-grant, or one past `max_bag` is a loud refusal.
- **Address-space copy is refused on every route.** `fork`, `reserve(@caller)` and
  `grant(address-space, …)` each print F2.
- **`seal` checks imports against bag + ambient** and emits the manifest.
- **`start` mints `running` only on evidence;** a stall goes to `abandon`.
- **The roster brackets every child,** and identities are never reused.

## Limits (rung 0/1)

- A child is an entry linked into the same image. It runs to completion inside `start`, so
  `wait` only collects its status.
- The bag is enforced at the `ChildCtx` seam, not by hardware or the MMU. This skeleton
  makes no isolation claim.
- Owed:
  - `replace`, `detach`, `revoke` and nested attenuation;
  - the Unikraft provider (posix-process, app-elfloader, Q32);
  - the compat layer (`lib/koruspawn`);
  - the fd census via `fcntl`.
- M9 is not passed by this. Q30 and Q33 stay open.

## Slice A ↔ Spawn mapping (Slice A is not migrated)

Slice A's supervisor stand-in (`koru/slice`) is unchanged. Its evidence (`88516f4`, `f408bc5`)
is frozen and depends on timing, so migrating it would mean re-freezing Slice A. That is the
next step, not this one.

| Slice A stand-in | Spawn |
|---|---|
| launch a view | `reserve` (identity minted, authority checked) |
| hand a binding to the view | `grant`. Difference: Slice A **moves binding custody**, while Spawn **attenuates a held handle** (the parent keeps it) |
| view admitted | `seal` (manifest) |
| view up on its first frame | `start` → `running` on evidence |
| view finished | `wait` + `reap` |
| timeout without a frame | `stalled` → `abandon` |

## Concordance

These are new terms, **proposed only** and not registered until Fabian OKs them: spawn,
grant, rights bag, seal, authority, seam, ambient set, abandon. The reference is `Cypoe/koru`
branch `ccomp`, `docs/concordance-matrix.md` (last changed in `a1218e1f`, tip `b39a442f`).
No second matrix is kept here.
