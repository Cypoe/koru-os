# Build-time resolution through realize table 3: acceptance (frozen before the counted runs; commit time is the freeze)

DESIGN-0001 §11.6 "not yet: the link phase proper", §3.4 (configure phase: a required
interface has no row → refusal), §3.5 (a non-empty table 3 produces no image).

What changed:

- **Two kinds of lookup.** `koruos/nid` now has `resolve`, a REQUIRED import, and `probe`,
  an OPTIONAL lookup. Both log `via=`. `boot_nid.k` uses `probe` for its two deliberate
  unbound names.
- **Build-time link phase.** `koruos/realize` evaluates the binding chain while building,
  as a link section of `realize.txt`:
  - It reads the export table from the `koruos/nid` module's own host lines, the same
    lines that are compiled into the image.
  - It admits every literal `open` manifest with the same rules as the lift.
  - It resolves every literal `resolve` and `probe` against the lexically enclosing table
    (`ok` arm of the open), and applies a literal `retarget` on its `ok` arm.
  - A REQUIRED import that cannot bind is a table-3 refusal: no Kraftfile, therefore no
    image. A `probe` is only predicted.
- **Not predicted:** run-time-only facts (generations, stale).

| id | criterion |
|----|-----------|
| L1 | agreement: the `predict:` lines of `realize.txt` (opens, resolves, probes, retargets) equal the image's run-time outcomes, in order, in every field printed: open ok rows or refusal reason; foreign, NID, row, interface, export, or missing+offered; retarget rows. Checked by `agree.py`, 3/3 boots |
| L2 | build-time refusals (`check-build.sh`). Required import with no row, required import at another version (offering the bound version), required import under a refused table, and required import with a 4-bit NID collision are each refused by `realize gen`, with no Kraftfile and no `.unikraft`. A satisfied required import and an unbound `probe` are accepted |
| L3 | the image still passes the NID run-time checks `../nid/check.py` N1–N10 3/3. Checker v2 differs from the frozen v1 only in N3, where the expected refusal lines now end in `via=probe` (the logging changed, the criterion did not). Plus R: kconfig derived, R2/R3, stack bound FITS |
| L4 | regressions: `../realize/run-counted.sh` (Slice A and DS0 3/3, R1–R6), since `koru/realize` changed |

PASS = L1–L4. QEMU TCG only.

Disclosed: an exploratory `realize gen` of `boot_nid.k` (`/workspace/nl1`) and one trial of
`check-build.sh` (`/workspace/nlneg`) were run while writing the tools. `agree.py` was run
once against the previous image's log, which predates `via=`, and failed as it should.
