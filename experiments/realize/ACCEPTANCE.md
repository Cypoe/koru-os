# Obligation-derived Unikraft kconfig: acceptance (frozen 2026-10-19 19:00 CEST, commit `c2f4de7`; counted runs 19:00:56–19:03:08)

DESIGN-0001 §11.1 (S1–S5), §11.5 item 2. Before this, koru-libs' `unikraft gen` wrote a
hand-pinned Kraftfile (`CONFIG_STACK_SIZE_PAGE_ORDER` 6, the scheduler always in, the
allocator lines written by the author). Here `koruc <boot.k> realize gen` (`koru/realize`)
derives the Kraftfile from the interfaces the program uses, through a row table, and refuses
when a used interface has no row or an author line contradicts a derived one.

Frozen before the counted runs. Exploratory builds made while writing the tools
(`/workspace/rz1`, `/workspace/rzneg`, not counted) are disclosed in README.md.
Programs: Slice A (`koru/slice/tests/boot_slice.k`) and DS0 (`koru/silo/tests/boot_silo.k`),
built by `build-realized.sh`, which only adds `import koruos/realize` and removes the two
allocator lines from the work copy. Toolchain and koru-libs (@ ff5cb559) as Slice A.
QEMU TCG only.

| id | criterion | how |
|----|-----------|-----|
| R1 | derivation: `realize gen` exits 0 for both programs; every derived kconfig line in the Kraftfile has a row in `realize.txt` table 1 or the stack line in table 2; the author block keeps only policy lines (no allocator, stack-order or scheduler line) | `realize.txt`, `Kraftfile`, `rg` on the work copy |
| R2 | concordance: every derived line holds in the resolved `.config.koru_qemu-x86_64` (`y` = `=y`, `n` = "is not set", numbers equal) | `check-config.py` |
| R3 | when realize chose the no-scheduler row: no symbol matching `uk_sched_*`, `*schedcoop*` or `uk_thread_*` in the image (`nm` on the `.dbg`) | `check-config.py` |
| R4 | stack: the conservative static demand from `ukplat_entry2` (the first function on the boot stack sized by `CONFIG_STACK_SIZE_PAGE_ORDER`) is ≤ the derived stack | `stack-demand.py` exit 0 |
| R5 | behaviour unchanged: Slice A frozen checks (`../slice-a/check.py`, S9–S14, x) PASS 3/3 on the derived image; DS0 (`../ds0-silo/run-image.sh`) PASS 3/3 on the derived image | counted runs |
| R6 | refusals: `negative_unrowed.k` (a lift without a row) and `negative_contradict.k` (author `CONFIG_LIBUKSCHEDCOOP: 'y'` against derived `n`) are refused with no Kraftfile; `control_rowed.k` is accepted | `check-negatives.sh` |

PASS = R1–R6 all hold, R5 3/3 on both programs. Reported, no criterion: image and `.text`
sizes against the pinned builds; the order-4 probe (stack-demand verdict and what booting it
does). An L1 oracle is never counted.
