# Slice A acceptance (frozen 2026-10-19 18:46 CEST in commit 88516f4, before the first counted run)

The slice is defined in DESIGN-0001 §11.4. The checks are implemented in `check.py` and
`check-negatives.sh` exactly as committed together with this file; a change to either after
this commit voids the counted runs. The rehearsals (`/workspace/slr1`, `/workspace/slr2`, box
only) were used to write the checks and are **not** counted.

**Arm.** Unikraft 0.21.0 (kraft `stable`), platform `qemu`, x86_64. The image is built by
`build-slice.sh` from `koru/slice` and koru-libs @ `ff5cb559` (`unikraft/`). It runs under QEMU
with TCG only, 32 MiB of RAM:
- COM1 goes to a file and carries the evidence log;
- `isa-debugcon` at port `0x402` goes to a unix-socket chardev (`server=on,wait=off`) and
  carries the status view.

`run-slice.py` attaches a host view at about 1.0 s, detaches it at 3.5 s, and reattaches it at
about 7.0 s until QEMU exits. There is no Linux ABI and no app-elfloader: the task is Koru plus
Zig in one image.

**Checks** (each must pass in 3 of 3 runs on the same kernel; the kernel's sha256 is recorded):

| id | check |
|---|---|
| S9 | the program declares the versioned imports `store.bounded@1`, `clock.tick@1` and `view.status@1` (an `import:` line with layout, entry size and an effects bound), each before its `bound:` line |
| S10 | from the good manifest, the loader binds `store.bounded@1` to `store_mem_v1`, whose artifact equals the build's sha256 of its source block. It names the passed-over candidates `store_mem_v2` (contract revision) and `store_wide` (entry size). `clock.tick@1` binds to `clock_uk_v1` and `view.status@1` to `view_debugcon_v1`, with matching artifacts |
| S11 | three manifests are refused at `phase=load`, before any child is reserved, with the fixed shape `refused: interface=… arm=… phase=… missing=… offered=[…]`: (1) wrong revision and wrong entry size; (2) an unauthorized artifact; (3) an artifact not linked into this realization, and a provider whose effects exceed the import. The roster is 0 afterwards |
| S12 | a real operation through the selected providers: ticks 1..30 (300 ms each, by `clock_uk_v1`) are appended to the bounded store (16 × 64 B ring, eviction counted). The read-back gives `entries=16 first=15 last=30`. Every binding has calls > 0 at release. The store's commit plus the budget left equals the child's budget (4096) |
| S13 | supervisor record and lifecycle, in this order: roster 0; child 1.1 is reserved, refused at seal (`missing=store`, empty bag) and abandoned; child 2.1 is reserved with the task's artifact; it gets three grants, is sealed and started (`ran=yes`, on evidence); roster 1 while it runs; it exits with status 0 after 30 ticks; it is reaped; roster 0. Exactly one `start` |
| S14 | the view detaches and reattaches without stopping the task: ≥ 3 frames before the detach, all `running`; a gap of ≥ 3.0 s with no connection; ≥ 3 frames after the reattach. The first frame after the reattach has a tick ≥ the last tick before the detach + 5, and its `held=lo..hi` covers the gap (lo ≤ last-before + 1, hi = its own tick). All frames show the same child identity `2.1`. The last frame is `exited` at tick 30 |
| x | QEMU exits 0; no `Unikraft Crash`; no line starting with `FAIL`; `slice-a: end` appears. The compile gates pass (`check-negatives.sh`): the control compiles, and `start` before `seal`, `grant` after `seal`, `reap` while running and a leaked running child are each rejected with KORU030 |

**Not claimed:**
- The child runs on the supervisor's thread (a module-owned body, as in `unikraft/sched`); there
  is no second thread and no address-space separation (rung 0/1; DESIGN-0001 §8.6.2).
- Artifact identity is the sha256 of the provider's **source** block, not of its linked bytes.
- The guest cannot observe whether a view is attached. That is the point of the renderer
  rule (§7), and it also means attach and detach are host-side events here.
- Authorization is an allowlist string passed with the manifest, not a signature.
