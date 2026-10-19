# Dissected Spawn, first measured skeleton: acceptance (frozen before the counted runs; commit time is the freeze)

DESIGN-0001 §8.6 (8.6.1 F1/F2/F3/F5/F9, 8.6.2 model and refusals, 8.6.6 evidence). The lift
is `koru/spawn/index.kz` (`koruos/spawn`). It has koru-libs shape and is not pushed to
`Cypoe/koru-libs` (Q33). The image is `koru/spawn/tests/boot_spawn.k`, built by
`build-spawn.sh`, with its kconfig derived by `koruos/realize` (a `koruos.spawn` row was
added). QEMU TCG only.

**In scope:** authority (the parent's held handles, its spawn authority with an image set,
`max_bag` and `max_children`), `reserve`, `grant`, `seal` (with manifest), `start` (on
evidence), `wait`, `reap`, `abandon`, and `fork`, which only refuses.

**Out of scope, owed:** `replace`, `detach`, `revoke`, nested attenuation, the Unikraft
provider (posix-process), the compat layer, and the fd census via `fcntl` (8.6.6, which
needs real fds). Rung 0/1: a child is an entry linked into this image and runs to completion
inside `start`, so `wait` only collects its status. The bag is enforced at the `ChildCtx`
seam, not by hardware.

| id | criterion |
|----|-----------|
| S1 | empty by default: a child with no grants sees `bag=0`. Its uses of `fd/1` and `env/TERM` are refused at the seam and it prints nothing through `fd/1`. Its manifest lists only the ambient set (memory ≤ budget, clock, exit, yield), and it reads the clock |
| S2 | explicit grants: the manifest emitted at seal is exactly `fd/1 write` and `env/TERM read`, and equals what the child sees. The granted write and read work; `read` on `fd/1` (not granted) is refused at the seam |
| S3 | `grant` refuses over-grant (`write+admin` where the parent holds `write`), a handle the parent does not hold, and a third grant beyond `max_bag 2`; none of them appears in the bag |
| S4 | address-space copy is refused loudly on every route: `fork`, `reserve(@caller)`, and `grant(address-space, copy)`, each naming F2 |
| S5 | `seal` refuses an image whose imports (`store/ring`) are not in bag + ambient; no manifest; the child is abandoned |
| S6 | `reserve` refuses an image outside the spawn authority (F9) and a third child beyond `max_children 2` |
| S7 | `start` mints `running` only on evidence: an image that never signals entry stalls and is abandoned |
| S8 | the roster brackets every child (`0 → 1 → 0`) and is 0 at the end (no zombie) |
| S9 | identities are minted at reserve, start at 2 (1 is the boot program), strictly increase and are never reused, also across refused and abandoned children (6 reserves) |
| S10 | compile gates (`check-negatives.sh`): both controls (the full order and the `abandon` escape) compile. `start` on staged, `grant` after `seal`, `reap` on running, and a leaked running child are KORU030 |
| S11 | `spawn: done`, no `FAIL` or `CRIT` |
| S12 | `revoke` marks the grant's epoch; the child's next use fails with `revoked` |
| S13 | nested attenuation: `authority-of` derives a child's authority; a grandchild over-grant is refused |
| R | `realize gen` derives the Kraftfile (koruos.spawn row), `../realize/check-config.py` R2/R3 PASS, `../realize/stack-demand.py` FITS |

PASS = S1–S13 and R in 3/3 boots of one image. Regressions, since `koru/realize` gained a
row: `../realize/run-counted.sh` (Slice A and DS0 3/3, R1–R6), plus the NID image
(`../nid/check.py` N1–N10 and `../nid-link/agree.py` L1, 3/3).

**Slice A wiring (decision):** keep both for now. Slice A's supervisor stand-in
(`koru/slice`) stays as it is, because its evidence is frozen (`88516f4`, `f408bc5`) and
depends on view timing. Migrating would re-freeze Slice A. The mapping is recorded in
`README.md`; the migration is the next step, not this one.

Disclosed: an exploratory build and one boot (`/workspace/sp1`) were made while writing the
checker, which was then dry-run on that log after its `abandon` wording was patched in text
(that run is not counted).

## M-SPAWN-MMU gaps (2026-10-19)

Gaps 1–3 PASS 3/3 under TCG (`experiments/m-spawn-mmu/`). Spawn acceptance: **ready for Fabian review**, not accepted. ELF child-CR3 remaining (see DESIGN-0001 M-SPAWN-MMU row).
