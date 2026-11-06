---
name: arm-python-emit
iface: koruos/std.emit-python
arms: [koru-native]
lane: koru-lift
needs: [py-cpython-child]
accept: a koru program emits .py and the CPython child runs it — the interpreter is an execution arm
tier: qemu
status: open
evidence: —
peer: upstream/koru compiler — the emit/target dialect machinery lives in the toolchain repo
provenance: —
---

# arm-python-emit

Python as a koru emit dialect: `std/target` gains a `python` arm so a
koru program compiles to `.py` source and runs under the CPython
child — the interpreter becomes a real execution arm in the realize
matrix (`arm: python-interp`), alongside `unikraft/*`, `hosted`,
`koru-native`.

## Acceptance

A fixture `.k` compiles with the python arm; the emitted `.py` lands
in the cpio, the CPython child runs it, and its print line matches
the oracle expectation. The realize matrix shows the python arm
column — bound rows bind, missing ones refuse by name.

## Notes

- The emitter itself is upstream/koru toolchain work (a new codegen
  dialect: proc bodies → python text); this slot tracks the *OS
  arm*: the interpreter provider, the realize row shape, and the
  boot evidence. Peer coordinate: koru compiler `std/target` arms.
- Once landed, koru lifts and existing CPython code (klanker) share
  one runtime child — the FFI question then shrinks to "same
  interpreter, same objects" instead of a wire protocol.
- Cheaper first FFI if the dialect is slow: a koru child and the
  CPython child talking a defined wire over a unix socket — that
  shape already exists (SCM_RIGHTS through real libwayland clients).
