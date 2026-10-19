# Obligation-derived Unikraft kconfig (DESIGN-0001 §11.1, §11.5 item 2)

`koruc <boot.k> realize gen` (`koru/realize/index.kz`) replaces the hand-pinned Kraftfile
written by koru-libs' `unikraft gen`. It walks the program's flows, collects every used
`module:tor`, maps each one through a row table and writes `Kraftfile`, `Makefile.uk` and
`realize.txt`, the three tables of §3.5:

1. interface → row → kconfig;
2. resource → mechanism → cost;
3. refusal or override.

A used interface with no row is refused. So is an author kconfig line that contradicts a
derived line. A refusal writes no Kraftfile (realize exits 3; koruc reports 1). Author lines
that are not derived are kept as reported policy overrides.

## Result: PASS (R1–R6, frozen in `c2f4de7`, counted 2026-10-19 19:00:56–19:03:08 CEST, TCG)

| id | result | evidence |
|----|--------|----------|
| R1 | both programs derive; their author blocks have 0 allocator, stack or scheduler lines | `evidence/{slice,silo}-realize.txt`, `evidence/r1-author-block.txt` |
| R2 | 5/5 derived lines hold in the resolved `.config`, for both programs | `evidence/{slice,silo}-config.txt` |
| R3 | 0 scheduler symbols in either image (the pinned builds have 20) | same |
| R4 | stack bound 76,544 B (Slice A) and 74,216 B (DS0), both within the derived 131,072 B | `evidence/{slice,silo}-stack.txt` |
| R5 | Slice A 3/3 PASS, DS0 3/3 PASS on the derived images; Slice A compile gates PASS | `evidence/slice-run-*.txt`, `evidence/ds0-run-*.txt`, `evidence/slice-compile-gates.txt` |
| R6 | the unrowed lift and the contradicting author line are refused; the control is accepted | `evidence/negatives.txt` |

Reported, no criterion:

- **Stack order.** The derived order is 5 (128 KiB); the pinned order was 6.
- **Image sizes** (`evidence/sizes.txt`). Slice A went from 197,504 to 193,200 B and DS0 from
  181,120 to 176,816 B. `.text` shrank by about 4.7 KB per image. That is the scheduler as it
  stands after `OPTIMIZE_DEADELIM`; the 99 KB BUILD.md figure does not reproduce here.
- **Order-4 probe** (`evidence/probe-order4.txt`). The stack bound refuses it, and booting it
  anyway crashes at 0.10 s.

Kernel hashes are in `evidence/*-kernel.txt`. Builds are not byte-reproducible, as with
Slice A.

Exploratory, not counted: while the tools were being written, `/workspace/rz1` (three Slice A
builds) and `/workspace/rzneg` (the negatives) were run before the freeze. They found:

- `koru:start`/`koru:end` are compiler markers and need the system list;
- the command leaked three small strings;
- the gate script had shell-precedence and exit-code bugs.

## Reproduce

```
PATH=/workspace/tc/koru/zig-out/bin:/workspace/tc/zig-x86_64-linux-0.15.2:/workspace/tc/kraft:$PATH
./run-counted.sh <koru-libs @ ff5cb559> <scratch> <evidence dir>
# single pieces:
./build-realized.sh <slice|silo> <koru-libs> <workdir> [stack-order override, probe only]
./check-config.py <workdir>/koruos/<p>/tests
./stack-demand.py <kernel>.dbg <derived stack bytes>
./check-negatives.sh <koru-libs> <workdir>
```

## Open (§11.1)

- **S3.** Report the `.eh_frame` cost and try `/DISCARD/`.
- **RAM floor.**
- **S4.** Derive the order from the measured bound instead of only checking it.
- **Rows still to write:** `unikraft/ninep` / 9P and `unikraft/sched` (only the no-scheduler
  arm has been exercised). The `koru.runtime` row's 16 KiB is an allowance (C).
- **Upstream shape.** Rows belong to the lifts that own them, not to one central table. This
  waits on the koru-libs home (Q33).
