# M-SPAWN-MMU (gaps 1–3)

Closes the three gaps before Spawn acceptance review:

1. **Parent heap/stack unmapped** in the child PT; private ambient stack+heap (VMA-backed); fault test that the child cannot read the parent heap; attenuation (RO grant).
2. **No MMU skip**: seal always derives a child PT (including zero mem grants / M9 foot / spawn-elf).
3. **Sched CR3 (4b)**: leave-to-parent before heap TLS/ctx access, arrive on resume; two concurrent children cannot see each other's secrets; stress ≥100 yields.

## Result (2026-10-19, Europe/Berlin CEST)

`evidence/gaps-accept/run-{1,2,3}/` — **M-SPAWN-MMU GAPS PASS 3/3** under TCG.

Spawn lib acceptance status: **ready for Fabian review** (not accepted).

## Remaining

- External ELF on **child CR3** still fails unikraft CRT/exception paths that touch the parent heap before the first syscall leave hook. `spawn-elf` keeps a derived+bound PT (rung=2) and runs the ELF on the parent CR3 until that path is CRT-safe. Gaps harness proves HW isolation.
- Q33 open → keep pushes to Cypoe/koru-os only; no GPL/images/WAD.

## Build / run

```bash
./build-image.sh
./run.sh /workspace/msmmu/.unikraft/build/m-spawn-mmu_qemu-x86_64 /tmp/gaps
python3 check.py /tmp/gaps
```
