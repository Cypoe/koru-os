# NID binding layer (DESIGN-0001 §11.5 item 3, result in §11.6)

`koruos/nid` (`koru/nid/index.kz`) implements the binding chain of §3.0:

```
foreign import --NID--> correspondence row --> canonical interface --> provider export
```

An unbound NID is a loud refusal, and nothing runs.

## Result: PASS 3/3 under TCG (checks frozen in `80afc1c`, 19:13:42 CEST; counted 19:13:55–19:14:30)

| id | result (each 3/3) |
|----|-------------------|
| N1 | 35 printed NIDs and interface ids equal the host's own sha256 recomputation |
| N2 | `c/libc/1/fputs` and `linux/x86_64/1/write` → `koruos.console.write@1` → `console_com1_v1:write`; outputs and return lengths correct |
| N3 | `c/libc/1/puts` refused with `offered=[none]`; `c/libc/2/fputs` refused with `offered=[c/libc/1/fputs]`; both `phase=link missing=correspondence row`; no provider output |
| N4 | `create` over a bound foreign name refused (no silent overwrite, unlike plex-core `bind_address`) |
| N5 | export realizing another revision, unlinked export, and orphan `evolve` refused at open |
| N6 | 4-bit table: `c/t/1/f02` vs `c/t/1/f01` refused as a real collision (host-confirmed) |
| N7 | retarget across revisions refused; retarget @1 → `console_tag_v1` moves 2 rows to gen 2; old binding `stale held=1 now=2`, its text never printed; re-resolve keeps the same NID and reaches the new export |
| N8 | `evolve` to @2 occludes row 0, which stays listed; resolve reaches `console_com1_v2` |
| N9 | both tables `close: outstanding=0`, `nid: done`, no FAIL or CRIT |
| N10 | the control compiles; call-after-release and resolve-after-close are KORU030; a never-released binding is auto-discharged |
| R | Kraftfile derived (koruos.nid row hit), R2/R3 PASS; stack bound 87,592 B fits the derived 131,072 B |

Image: `ecdecd9d…` (`evidence/kernel.txt`), 209,584 B. Wall time per boot is in
`evidence/run-*.txt`. Regressions after `koru/realize` gained a row: Slice A 3/3 and DS0 3/3,
realize R1–R6 PASS (`evidence/regress-realize.txt`).

**Findings** (also in DESIGN-0001 §11.6):

- **Auto-discharge order.** The auto-discharged `release` is emitted after the explicit
  `close`. The lift guards against this at run time: close keeps a table that has
  outstanding bindings.
- **Stack bound.** The conservative bound exceeds the declared row sum by 1.5 KB through
  the charge for indirect calls. It stays within the 25 % margin.

## Reproduce

```
PATH=/workspace/tc/koru/zig-out/bin:/workspace/tc/zig-x86_64-linux-0.15.2:/workspace/tc/kraft:$PATH
./build-nid.sh <koru-libs @ ff5cb559> <workdir>
./check-negatives.sh <workdir> > gates.txt
./run-nid.sh <workdir>/koruos/nid/tests/.unikraft/build/koru_qemu-x86_64 <rundir>
./check.py <rundir> gates.txt
```

## Concordance

Cited against the ccomp matrix: `Cypoe/koru`, branch `ccomp`, `docs/concordance-matrix.md`.
The file was last changed at `a1218e1f`, and the tip was still `b39a442f` when re-read on
2026-10-19 at 19:08 CEST.

**Existing rows used:**

- `tor`, `proc` (§1);
- `mint` (canon-alias (p)): `open` and `resolve` mint obligations;
- `custody` (warranted neologism (p)): a binding's interval from `resolve` to `release`;
- `take` / `discharge` (std/store): `release` and `close` discharge.

**Not in the matrix yet:** `NID`, `correspondence row`, `live binding`, `generation`,
`retarget`, `occlude`. Their proposed rows (term · nearest canon · delta, ruling `unplaced`)
are in DESIGN-0001 §2.2 and are now marked in tree. Registering them in the ccomp matrix is
an upstream change to `Cypoe/koru`. It is not pushed from here, and per §2.3 there is no
second matrix.
