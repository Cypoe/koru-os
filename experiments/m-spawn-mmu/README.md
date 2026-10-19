# M-SPAWN-MMU

DESIGN-0001 §8.6.7c. Local in koru-os (Q33 still open). Concepts align with
`Cypoe/koru-libs` `unikraft/paging` + `unikraft/vmem`.

Implementation: `lib/koruspawn/mmu.c` (+ seal/revoke/`ksp_grant_mem` in `koruspawn.c`).

## Milestone goal

Per-child page tables; object ≠ vaddr ≠ permission ≠ residency; CoW/share only
as an explicit Spawn grant; hostile child cannot read ungranted parent pages
(hardware fault). TCG only.

## Steps (measured vs design)

| Step | Claim | Class |
|---|---|---|
| 1 | `uk_paging_pt_clone` + unmap + nofault + remap grant | **M** (earlier) |
| 2 | Seal derives child PT from mem/obj grants; RO/RW/X attenuated; revoke unmaps + TLB flush + epoch | **M** 3/3 |
| 3 | `cow` verb = dissected-fork AS-copy grant (explicit, per region); ambient AS refused; `cow_break` private RW | **M** 3/3 |
| 4 | CR3 switch to child PT / back to parent; secret fault in child AS | **M** 3/3 (probe) |
| 4b | Full posix multi-AS for every spawn-elf child (sched CR3-on-switch, always-on) | **D** — PT switch only when mem grants present; no ambient mem grants in spawn-elf suite today |
| — | Move to koru-libs | **blocked on Q33** |

Evidence: `evidence/run-{1,2,3}/` — `M-SPAWN-MMU STEPS PASS`. Board: `evidence/BOARD.txt`.

## Build / run (TCG)

```bash
./build-image.sh
./run.sh <kernel> evidence/run-1
python3 check.py evidence/run-1
```

## Spawn conditional acceptance

With steps 2–4 measured and M9/spawn/spawn-elf/Slice A regressions green, the
**conditional** Spawn-lib acceptance (Fabian on `dcf7b75`) is **ready for Fabian
review**. It is **not** marked accepted here.
