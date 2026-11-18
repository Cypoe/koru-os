---
name: cage-wayland
iface: koruos/oracle.compositor
arms: [koru-native]
lane: oracle
needs: [foot-wayland, clone-threads]
accept: unmodified upstream cage nests on wlserver and hosts Debian foot with real composited pixels
tier: qemu
status: landed
evidence: V
peer: —
provenance: cage v0.1.5 tarball sha256 576b8b5a…b2b5, vendored unmodified in koruos/hosted/cage (MIT)
---

# cage-wayland

The real-compositor oracle: upstream **cage 0.1.5** — a real wlroots
0.16 kiosk, unmodified — runs its wayland backend NESTED on our
libwayland-server compositor (`wlserver`, `/wayland-1`), mints its own
socket `/wayland-0`, and its primary-client path fork+execvps Debian's
unmodified `foot`. Four real protocol hops carry the pixels:
`foot → cage → wlserver → *Surf → virtio-gpu`.

## Acceptance

Met. `cage-real` in `scripts/check-boot.sh` asserts serial evidence:
`CAGEINIT wayland-1 bound` + `cage forked` (orchestration), `WLSRV
appid wlroots` + `comp: paint 12..x720 nb=…` (cage's own nested output
composited to the gpu), `WLSRV title foot` + `comp: paint NNNxNNN
nb=…` (foot's shm frame composited inside cage — nonzero pixels on a
sub-output-sized surface), `CAGEINIT SHELLPROOF` (foot's pty chain ran
a real program), and `CAGE COMPLETE` (the epoch drained — every
descendant reaped).

## Kernel deltas this rung exposed

- `recvmsg` SCM_RIGHTS drained LIFO — two pool fds in successive
  sendmsg calls arrived reversed; wl_shm demarshal handed
  `create_pool` the wrong fd and libwayland killed the client.
  Drains FIFO now — a real protocol-correctness bug foot's single-fd
  sends never exercised.
- `clone3` arm: parses `struct clone_args`, validates, folds into the
  clone register shape — WITHOUT rewriting the trap frame, because
  glibc's `__clone3` hands the thread its func/arg through preserved
  user regs (`rdx`/`r8`). `pidfd` is flag-gated like linux (ignored
  unless `CLONE_PIDFD`); `set_tid`/`cgroup` refuse by name.
- `exit_group` status masking: a propagated negative errno
  (`exit(-26)`) hit a checked intCast in the SIGCHLD record — linux
  masks to the low byte; ours now does before both the siginfo store
  and the wait-word encode.
- `loadElf`/`loadElfViaFs` phdr guards ordered so file-controlled
  u64 fields can't wrap a checked add into a kernel panic — a corrupt
  payload is an `ELF REFUSE`, never a `ud2`.
- `MAXCHILDREN` 8→16, eventfd/timerfd/socket/pty/pipe pools widened —
  one nested compositor + one real client exceeded the single-client
  waterline.
- Upstream bug found, not masked: cage 0.1.5's `handle_signal` is
  handed `&server.wl_display` (a `wl_display**`) but reads
  `wl_display*` — `wl_display_terminate` writes to garbage
  `terminate_efd` and libwayland aborts identically on real linux.
  Orchestration uses `SIGKILL`; the upstream defect is documented in
  `cageinit.c`, not patched.

## Notes

- `wlr_deps.sh` shares the vendored dep compile between
  `build-wlrcomp.sh` and `build-cage.sh` so the two consumers cannot
  drift.
- Refusals the workload survived honestly: `fallocate` PUNCH_HOLE
  (foot warns "expect lower performance"), `sched_getattr`/
  `sched_getaffinity` (glibc fallbacks), `fadvise64` (bag refusal —
  advisory).
- Next rung up the same ladder: multi-client compositor sessions,
  then Hyprland-class protocols (`wlr_layer_shell`, `zwlr_foreign_toplevel`).
