# Arm-gap enumeration: `realize gen --arm koru-native`

Evidence class: M (generated on the Windows box, 2026-10-21; koru-os @ post-9b80510)

## Method

The row table is the contract; an arm's binding set is what it can serve. Running
`realize gen --arm <id>` for an arm that has no bindings yet is therefore not an
error path — it is the enumeration of the provider gap for that arm. Every
`refused:` line is one provider a standalone substrate must supply, produced by
the gate rather than hand-listed.

## Result (control program: print only)

```
refused: interface=koru.runtime arm=koru-native phase=configure
         missing=runtime binding for arm
refused: interface=std.io:print arm=koru-native phase=configure
         missing=binding for arm (row serves: unikraft/qemu-x86_64,hosted)
```

## Result (DS0-shaped program: silo + print)

```
refused: interface=koru.runtime arm=koru-native phase=configure
         missing=runtime binding for arm
refused: interface=koruos.silo:open arm=koru-native phase=configure
         missing=binding for arm (row serves: unikraft/qemu-x86_64)
refused: interface=std.io:print arm=koru-native phase=configure
         missing=binding for arm (row serves: unikraft/qemu-x86_64,hosted)
not-applicable: author kconfig line CONFIG_OPTIMIZE_SIZE: 'y' (arm=koru-native)
not-applicable: author kconfig line CONFIG_LIBUKALLOC: 'y' (arm=koru-native)
```

## What the standalone arm must provide (from the rows' resource columns)

| refused interface | the provider it needs (from row `resources`) |
| --- | --- |
| `koru.runtime` | heap: an allocator contract for the emitted prologue (today `posix_memalign`/`free`) + stack discipline |
| `std.io:print` | console write (today `fputs` on the Unikraft console, `host-libc` on hosted) — a serial/VGA sink |
| `koruos/silo` | entropy (`rdrand` or equivalent) + heap for handle records |
| `koruos/slice` | monotonic clock + debug channel (today `ukplat_monotonic_clock`, isa-debugcon) |
| `koruos/nid` | clock + console + heap |
| `koruos/spawn` | clock + console + heap (child records) — plus the M-SPAWN-MMU page-table seam natively |
| `unikraft/sched` | cooperative threads — the native arm needs its own scheduler row or none |

This is minimal because the row catalog is minimal: the gap table grows as the
m* experiments bind more interfaces (blk/kms/input/…). Each new measured row
makes the enumeration more complete — the table is derived, never maintained.

## Semantics fixed in this slice

- A used interface whose row exists but has no binding for the selected arm is a
  `missing=binding for arm (row serves: …)` refusal — including `std.io:print`.
  The pre-refactor `std, pure` escape now applies only to std modules with *no
  row* (pure codegen, no arm mechanism).
- `koru.runtime` is the always-on row; on an arm it does not serve it refuses
  first, because every program needs it.
