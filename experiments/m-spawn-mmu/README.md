# M-SPAWN-MMU (first measured step)

DESIGN-0001 §8.6.7c. Local in koru-os (Q33 still open). Concepts align with
`Cypoe/koru-libs` `unikraft/paging` + `unikraft/vmem`.

## Goal (milestone)

Per-child page tables; object ≠ vaddr ≠ permission ≠ residency; CoW/share only
as an explicit Spawn grant; hostile child cannot read ungranted parent pages
(hardware fault). TCG only.

## Step 1 (this directory) — measured vs design

| Claim | Status |
|---|---|
| Clone parent PT (`uk_paging_pt_clone`) as the dissected-fork address-space copy | **measured** |
| Default: drop ungranted secret from child PT (`uk_paging_page_unmap` + KEEP_FRAMES) | **measured** |
| Child cannot probe secret (`uk_nofault_probe_r` + NOPAGING → 0 bytes) | **measured** (fault-on-violation) |
| Explicit grant remaps the same frame into the child; probe succeeds | **measured** |
| Parent PT / secret intact across the switch | **measured** |
| Full Spawn `reserve/grant/seal/start` wiring of PT domains | **design** (next) |
| CoW PTE (write faults allocate a private frame) as a grant verb | **design** |
| posix-process multi-AS (`clone` without `CLONE_VM`) | **design / open** (today refused; M-SPAWN-MMU replaces that path) |
| Move provider to koru-libs | **blocked on Q33** |

## Build / run (TCG)

```bash
./build-image.sh          # W=/workspace/msmmu
./run.sh <kernel> evidence/run-1
python3 check.py evidence/run-1
```

Repeat for run-2, run-3. Board: `evidence/BOARD.txt`.
