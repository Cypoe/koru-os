# M-SPAWN-MMU (gaps 1–3)

Closes the three gaps before Spawn acceptance review:

1. **Parent heap/stack unmapped** in the child PT; private ambient stack+heap (VMA-backed); fault test that the child cannot read the parent heap; attenuation (RO grant).
2. **No MMU skip**: seal always derives a child PT (including zero mem grants / M9 foot / spawn-elf).
3. **Sched CR3 (4b)**: leave-to-parent before heap TLS/ctx access, arrive on resume; two concurrent children cannot see each other's secrets; stress ≥100 yields.

## Result (2026-10-19, Europe/Berlin CEST)

`evidence/gaps-accept/run-{1,2,3}/` — **M-SPAWN-MMU GAPS PASS 3/3** under TCG.

Spawn lib acceptance status: **ready for Fabian review** (not accepted).

## Remaining

- External ELF runs on **child CR3** (see below).
- Q33 open → keep pushes to Cypoe/koru-os only; no GPL/images/WAD.

## Build / run

```bash
./build-image.sh
./run.sh /workspace/msmmu/.unikraft/build/m-spawn-mmu_qemu-x86_64 /tmp/gaps
python3 check.py /tmp/gaps
```

## ELF child-CR3 (gap close)

**Chosen: kernel-half mapping + syscall/exception CR3 leave** (not a per-child
allocator arena, not CR3-only without a mapped assist).

Why this is the soundest of the three options:

1. **Kernel-half (shared RO boot text/.bss + per-child ambient stack/heap)** —
   `pt_clone` keeps boot-mapped unikernel text; VMA strip removes parent
   heap/stack; `ksp_mmu_provision_ambient` dual-maps private frames into child
   and parent PT at the same VA. The ELF entry pivots SP onto ambient, then
   activates the child CR3. Never remap the parent heap into the child.
2. **Syscall enter/exit CR3 leave** — already paired in `mmu.c` so unikraft
   heap TLS/syscall paths run on the parent PT; sched leave/arrive for yields.
3. **Rejected: per-child allocator arena alone** — does not stop CRT/auxv from
   chasing parent pointers, and would still require parent heap pages in the
   child PT (the gap). **Rejected: CR3 switch alone without ambient assist** —
   exception/CRT paths need a mapped stack before the first leave hook.

AT_RANDOM and AT_EXECFN are copied onto the child stack (`lib/koruelf/elf_ctx.c`)
so the static-pie CRT never dereferences parent heap through auxv.

