# Slice A: contract, supervisor and a detachable view in one Koru image

DESIGN-0001 §11.4. The lift is `koru/slice/index.kz` (module `koruos/slice`); the program is
`koru/slice/tests/boot_slice.k`. The acceptance criteria are in `ACCEPTANCE.md`, frozen before
the counted runs.

Build and run (TCG only):

```
PATH=/workspace/tc/koru/zig-out/bin:/workspace/tc/zig-x86_64-linux-0.15.2:/workspace/tc/kraft:$PATH
./build-slice.sh <koru-libs @ ff5cb559> <workdir>
./check-negatives.sh <workdir> > gates.txt
./run-slice.py <workdir>/koruos/slice/tests/.unikraft/build/koru_qemu-x86_64 <rundir>
./check.py <rundir> <workdir>/koruos/slice/artifacts.txt gates.txt
```

Concordance: the new terms used here (`spawn`-shaped child record, `grant`, `rights bag`,
`seal`, `reap`, `abandon`, `realization`, `interface descriptor`) are to be registered against
the ccomp matrix, `Cypoe/koru` branch `ccomp`, `docs/concordance-matrix.md` (DESIGN-0001 §2.3).
