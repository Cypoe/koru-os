# NID binding layer: acceptance (frozen before the counted runs; commit time is the freeze)

DESIGN-0001 §11.5 item 3; §3.0 binding chain, §3.1 identities, §3.2 rows and resolution scope,
§3.3 generations, §3.4 refusal shape, §8.7 "an unbound NID fails loudly". The lift is
`koru/nid/index.kz` (module `koruos/nid`, koru-libs shape, Q33 open). The image is
`koru/nid/tests/boot_nid.k`, built by `build-nid.sh` with its kconfig derived by
`koruos/realize` (a `koruos.nid` row was added). QEMU TCG only.

NID scheme (DESIGN-0001 Q3, answered here by construction, not by a design question):

- **nid** = first 8 bytes of `sha256("koruos.nid.v1|" + scheme/ns/version/name)`, rendered
  as 11 base64url characters;
- **iid** = the same over `"koruos.iid.v1|" + name@rev`.

A table may narrow NIDs to fewer bits, which is used only to force a collision in N6.
Collisions are refused, never first-come.

| id | criterion |
|----|-----------|
| N1 | every `nid=`/`iid=` the image prints equals the host's independent recomputation (≥ 20 ids) |
| N2 | `c/libc/1/fputs` and `linux/x86_64/1/write` (different NIDs) both bind to `koruos.console.write@1` → `console_com1_v1:write`, gen 1; each call prints its line and returns its length |
| N3 | `c/libc/1/puts` (no row) and `c/libc/2/fputs` (another version) are refused **by the layer** with the fixed shape `foreign nid arm phase=link missing=correspondence row offered=[..]`, the second offering `c/libc/1/fputs`; no provider output until the next binding |
| N4 | `create` on a foreign name that already has a row is refused (no silent overwrite), and no table opens |
| N5 | admission against this realization's exports: an export that realizes another revision, an export not linked into the image, and an `evolve` without a parent are each refused at open |
| N6 | with 4-bit NIDs, 17 distinct names are refused with `nid collision`, and the two names named really collide under the host's recomputation |
| N7 | retarget across revisions is refused. Retarget of `koruos.console.write@1` to `console_tag_v1:write` moves 2 rows to gen 2 with NIDs unchanged. The old binding is refused `stale held=1 now=2` and its text never appears. Re-resolving the same foreign name gives the same NID, the new export, gen 2, and its output |
| N8 | `evolve` to `@2` occludes row 0. Resolve binds row 1 (`@2`, `console_com1_v2`), and `close` still lists row 0 as OCCLUDED (evolve, don't mutate) |
| N9 | both tables close with `outstanding=0`, `nid: done` is printed, and there is no `FAIL` or `CRIT` line |
| N10 | compile gates (`check-negatives.sh`): the control compiles. Call-after-release and resolve-after-close are KORU030. A never-released binding is auto-discharged (koruc emits `release`) |
| R  | `realize gen` derives the Kraftfile (koruos.nid row hit), `../realize/check-config.py` R2/R3 PASS, `../realize/stack-demand.py` FITS |

PASS = N1–N10 and R hold in 3/3 boots of one image. Regressions: `../realize/run-counted.sh`
(Slice A and DS0, 3/3 each, R1–R6), because `koru/realize` gained a row.

Disclosed: exploratory build `/workspace/nid1` and one boot were made while writing the
checker (not counted). `check.py` was mutation-tested on a copy of that log: a changed NID
character fails N1, and a redirected stale call fails N7.
