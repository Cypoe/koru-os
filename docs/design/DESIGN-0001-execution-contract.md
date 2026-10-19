# DESIGN-0001: The koru-os execution contract

Status: DRAFT 5, 2026-10-18 (DRAFT 1 07:51; DRAFT 2 07:58: §2 replaced by a pointer to the ccomp concordance matrix, "arm" renamed "platform arm"; DRAFT 3 08:05: §8 security target model, §9 associative memory as a later rung, Appendices A and B; DRAFT 4 13:08: §0 Definition of Done set by Fabian (DoD-1..4, arm analysis, cyberboot, milestones M0–M10), R-DOD rows, Q16–Q22, Appendix C; DRAFT 5 19:26: Fabian's rulings: L1 is oracle only, driver silos (LKL accepted, KolibriOS second source), QML as canonical DoD-4 exemplar, DS0–DS4, R-SILO, Q17/Q20/Q21 closed, Q23–Q27; progress 20:30: DS0 in-image, M2 and M3 measured under TCG, see §0.4; progress 2026-10-19 13:10: M4 stand-in (a)–(d) 3/3, M5a 3/3, §0.4; 13:40: M6 decision (native KMS provider behind `kms.*`, DS3 open, Q28) and M6 3/3, §0.4; 14:10: M7 decision (native i8042 provider behind `input.*`, DS4 open), M7a 3/3, M7b open (B15), §0.4; 14:15: M8 split, M8a frozen and 3/3; 14:31: M8b (kmscube) 3/3, regressions 3/3, §0.4; 15:20: M7b (libinput via kernel sysfs + libudev-zero) 3/3, B15 resolved; 15:25: M9 frozen, first probes; 15:32: seat + udev monitor + card0 enumeration pass, next stop PRIME (B18), §0.4; 15:50: B18 resolved, Hyprland renders its first frame, `/tmp/dod3` policy decided; 15:55: Q28 closed by Fabian (native first, DS3/DS4 later as a milestone of their own); 17:15: foot runs as a Hyprland window (probe 8); 17:42: M9 check decisions; 17:43–17:47: M9 counted 3/3, not passed as frozen ((h2a) needs fork, Q29), regressions 3/3; 18:20: Q29 ruled by Fabian, M9 stays open; 18:45: §8.6 Spawn (dissected fork) drafted, Q19 directed, Q30–Q34 opened; 18:30: execution-contract guidance from Fabian folded in: §3.0 layering, §3.1 identity records, §3.6 interface descriptor and binding admission, §3.7 two obligations, §3.8 memoized resolution, §6.1a one address-space regime and reservation costs, §8.6.8 Spawn cross-links, Q35–Q36; 18:35: second paste folded in: §3.0 binding chain, §3.1 NID scope, §3.2 resolution scope, §3.6 narrow ABI claim, §7 session refinement and operational test, §11.0 realization graph, §11.4 Slice A, §0.4 priority vs ladder, Q37; 18:40: whitepaper ch.06/08 analysis folded in: counting wall closed at design level via §8.5 (M owed), §2.3 concordance gate (ccomp matrix is the seed), §4.1 FASM dialect no / KolibriOS donor-only, §8.7 whitepaper↔koru correspondence, §11.5 work list, Q38; 18:46: Slice A checks frozen (`88516f4`); 18:48: Slice A 3/3 PASS under TCG, §11.4 result; 18:59: Q19 closed by Fabian (DoD-2 reformulated only after Spawn-lib acceptance); 19:05: obligation-derived kconfig (`koruc … realize gen`) measured, §11.1 result; 19:17: NID binding layer `koruos/nid` N1–N10 3/3 PASS, regressions 3/3, §11.6, Q3 answered by work; 19:27: build-time resolution via realize table 3, L1–L4 PASS, §11.7; 19:37: Spawn skeleton S1–S11 3/3, §8.6.7a; 20:00: replace/detach/revoke/nested + Unikraft provider + loud compat, external ELF child E0–E12 3/3, skeleton S1–S13 3/3, §8.6.7b) (Europe/Berlin, CEST). Owner: koru (agent) for Fabian Schindler.
Scope: the first design note for koru-os. It defines the contract every platform arm must satisfy
(identity, correspondence, binding, refusal, evidence), states what Koru already provides,
and fixes a first vertical slice.

Pinned sources (all read through the GitHub connector on 2026-10-18 unless marked):

| repo | SHA | how read |
|---|---|---|
| korulang/koru | `3d81f837f63dc9eb0b5a5a6f96e17e09f3cc0aeb` (main, 2026-10-17) | tree + selected files |
| Cypoe/koru (branch `ccomp`) | `601ba53db4ff993c2f8584847b655bed6cfe70ee` | `docs/concordance-matrix.md`, branch compare vs upstream |
| korulang/koru-libs | `ff5cb559e1c00431a1bb36024871c760a9bdcbe9` (2026-10-13) | tree + selected files |
| Cypoe/plex-shell | `f34e473fbe77da06c36e6c745d8880f20d99dccc` | full mirror, built and tested on the box |
| Cypoe/isar-proofs | `b9534379573d8371dfc7b59d310b647942b9043b` | cloned, grepped |
| KolibriOS/kolibrios | `69df00612b371152a24f08a19af98b9ee44d556f` (2026-10-17) | `kernel/trunk` listing and licence only |

Evidence classes used throughout:

- **V**: verified now. Read at the pinned SHA by this author.
- **M**: measured on the box by this author. A log path is given.
- **C**: carried-over claim. Repo-reported numbers, or statements from the planning
  transcript, that were not re-derived.
- **D**: design only. Nothing exists yet.
- `?` (DRAFT 4) is not a class. It marks a hypothesis, such as an expected syscall, that becomes
  M only when a trace on the box confirms it.

Companion notes: `notes/plex-os-study.md`, `notes/plex-shell-crates.md`.

---

## 0. Definition of Done (set by Fabian Schindler, DRAFT 4)

koru-os is **done** when all four items below pass their acceptance tests in QEMU on
the box **on a koru-os arm (L2 or L3) with drivers in driver silos (§0.6)**. A pass on
hosted Linux (L1) does not count (Fabian, DRAFT 5); L1 is the oracle and trace source only. Evidence goes with logs and screenshots filed under `notes/evidence/`. Nothing short of that is
called done. This section says what each item demands from the platform arms
(§4), what exists, what is missing, and the milestone ladder. Detail (dependency stacks,
syscall and ioctl rows) is in Appendix C.

| # | DoD item | acceptance oracle (independent of koru-os code) |
|---|---|---|
| DoD-1 | A real filesystem. koru-os's own object/store shape (§3, §9) may differ, but at least one real FS driver allocates blocks on a block device | host `e2fsck -fn` (or `fsck.fat -n`) on the guest's disk image is clean, and host `debugfs`/`mtools` read back the file the guest wrote |
| DoD-2 | A real shell and real programs. `cyberboot` is the named test | a scripted serial session against an unmodified shell binary, plus the cyberboot trace in §0.2 |
| DoD-3 | A real Wayland compositor by vaxry (Hyprland) with one real terminal emulator as a window | QEMU `screendump` shows the terminal window; keystrokes injected over QMP produce a file the host can read afterwards; `hyprctl clients` lists the terminal |
| DoD-4 | Everything else: declarative UI. QML (Qt Quick) is the canonical exemplar (§0.3) | a QML surface (quickshell bar) renders on the DoD-3 compositor; screendump plus hot-reload check |

### 0.1 Where each item can run: the honest arm analysis

DoD-2 (real programs), DoD-3 and DoD-4 are defined by **unmodified Linux userspace**.
Hyprland, Mesa, foot and Qt are not portable to a new kernel interface without a
large porting effort. They expect the Linux system-call ABI, the DRM/KMS ioctl set,
evdev, udev-style device discovery, `memfd`/shared memory, futexes, threads,
`epoll`, Unix sockets with fd passing (`SCM_RIGHTS`), and a dynamic loader. So the
route to DoD is a **Linux-ABI personality**. A native koru-os interface comes after,
not before. Three routes exist, in increasing order of koru-os ownership:

| route | what binds the Linux ABI rows | cost | what koru-os then owns |
|---|---|---|---|
| **L1 hosted Linux arm** (Linux kernel in the guest; koru as the default Zig/hosted backend) | the Linux kernel | lowest: everything in DoD-1..4 exists upstream | nothing for DoD: **oracle and trace source only** (Fabian, DRAFT 5). A pass here proves Linux, not koru-os |
| **L2 Unikraft binary-compat arm** (`app-elfloader` + `syscall_shim`) | Unikraft `posix-*` libraries and `vfscore` (C, Unikraft docs) | medium for DoD-1/2; **very high** for DoD-3/4 without driver silos, because Unikraft has no DRM/KMS, evdev or udev surface that this author could find (unknown, see Q16) | the kernel side of every row it binds; the rows are the koru-os contract |
| **L3 projected syscall table** (koru-native personality: each Linux syscall/ioctl is an identity, bound by a correspondence row to a koru proc, or refused loudly) | koru code, possibly lifting Unikraft or donor drivers | highest | everything; L2 can be the first binding source for many rows |

Position (Fabian's ruling, DRAFT 5): **L1 is the reference oracle and nothing more. L2
is the first real arm, and L3 is the contract both are written against.** Linux does
come back, but only as a **driver personality** inside a driver silo (§0.6). It is never
the OS. Every milestone runs first on L1 to record the expected syscall/ioctl trace
(`strace -f`), and that trace *is* the row set the L2/L3 arm must bind or refuse. An
unbound row must produce a loud refusal naming the identity (R-REF), never a silent
`ENOSYS`.

### 0.2 What `cyberboot` is (V) and how it becomes an acceptance test

Two pieces of Fabian's code carry the name. Neither is the KPMG "Cyberboot" bootcamp
that a web search returns.

1. **plex-os `cyberboot` (V, plex-shell @ `f34e473f`,
   `crates/plex-os/src/cyberboot.rs`, 288 lines).** This is a bare-metal `.anim`
   player. It parses a header (`fps:` clamped to 1..60, `loop:`) and
   `[FRAME_n]` blocks. It trims and centres each frame in an 80×25 VGA text grid with
   ANSI colour runs, presents the frame atomically (`vga_present_text_frame`), mirrors
   it to COM1 and paces it with the PIT (`sleep_ms`). Assets: `plexus_boot.anim` (16
   frames, played at boot from `kernel_main`), `demo.anim` (6) and `boot.anim` (175
   frames, 816,702 B, `fps: 24`), reachable as REPL `anim demo|boot`. **M:** this
   author's QEMU run (`notes/evidence/plexos-serial.log`) shows the boot frames on
   serial before the `plex-os>` prompt. The plex docs (`04_VAND_AND_PROVENANCE.md`,
   C) describe the older cyberboot as "UEFI ASCII & framebuffer experiments: ASCII
   art boot sequence transitioning into direct graphics framebuffer dissolve". That
   UEFI original was not found in any repo this author can read (Cypoe/*,
   Lolaplex/*; `Lolaplex/plexus` is empty).
2. **`Cypoe/boot-animator` (V @ `d1e5d49b`, 2026-05-13, Rust, `libc` + `tokio
   full`).** This is the same animation run as a **Linux early-userspace program**.
   It opens `/dev/tty1` (falling back to `/dev/tty`), asks `ioctl(TIOCGWINSZ)` for the
   size, and picks `/assets/{220x50,120x36,80x24}.anim`. It spawns
   `/bin/ascii-animator play <file>`, then waits on a tokio `select!` between
   `SIGUSR1` (kill the child, emit `ESC[2J ESC[1;1H`, exit 0) and the child exiting.
   **`/bin/ascii-animator` is not in that repo or in any repo found (Q18).**
   **Fabian (2026-10-18, 19:32 CEST): `cyberboot` *is* `Cypoe/boot-animator`.** The pushed
   state (`d1e5d49b`) is old. It lacks the demo `.anim` files and `/bin/ascii-animator`,
   and the newer state is probably not pushed.
3. **`Cypoe/cyberboot` (checked 2026-10-18, 19:23 CEST; superseded by the note above).** The GitHub connector cannot see
   it (`scm_repo_not_accessible`). The public URL returns 404. It was not among the 25
   Cypoe repositories the connector lists. Either it was never pushed, or it is private
   and not granted to the connector. This note treats it as **likely not pushed**. No
   SHA is pinned, and `ascii-animator` remains missing.

**What cyberboot exercises**, which is why it is a good test. The kernel-side surface
is from reading the code (V). Exact syscalls marked `(?)` are hypotheses. `?` is not
an evidence class: such an entry becomes M only when an `strace -f` on L1 confirms it.

| capability | plex-os cyberboot (bare metal) | boot-animator (Linux userspace) |
|---|---|---|
| timing | PIT ticks | tokio timers → `clock_gettime`, `epoll_wait` timeouts (?) |
| display | VGA text memory + COM1 | tty device: `openat("/dev/tty1")`, `ioctl(TIOCGWINSZ)`, ANSI writes |
| storage | assets linked in (`include_str!`) | real FS reads of `/assets/*.anim`, `stat` (`Path::exists`) |
| processes | none | spawn: `clone`/`vfork`+`execve` or `posix_spawn` (?), `wait4`, `kill` |
| threads | none | tokio multi-thread runtime: `clone3`/`clone`, `futex`, `sched_getaffinity` (?) |
| events/signals | none | `rt_sigaction`, `rt_sigprocmask`, signal wake-up via socketpair/pipe, `epoll_ctl`/`epoll_wait`, `eventfd2` (?) |
| integration | boots to REPL | init-style contract: something must deliver `SIGUSR1` when boot is done |

**Acceptance test T-CYB (D; runs with a labelled stand-in until Fabian pushes the newer boot-animator state, Q18).** This test is a DoD-2 gate. Run it on L1 first, then on
the L2 arm.
1. A disk image with an ext2 root holds `/bin/boot-animator`, the animator binary
   (**stand-in**: the plex-libs `anim.rs` player built for x86_64-linux-musl and installed
   as `/bin/ascii-animator`, playing plex-os `boot.anim` data. Every log and screendump
   from it is labelled `STAND-IN`. It is to be replaced when the newer boot-animator
   state is pushed), and `/assets/80x24.anim`. Use the plex-os `boot.anim` re-cut to 80×24 if no
   other asset exists.
2. QEMU starts with `-serial file:…` and `-device virtio-blk-pci`. A tiny init runs
   boot-animator on the console, sleeps *k* frames, then sends `kill -USR1`.
3. Pass when all of the following hold:
   - (a) the serial log contains `Detected TTY size: 80x24` (or the configured size);
   - (b) the log contains at least *n* distinct frame bodies, in the order of the asset;
   - (c) after the signal, the log contains `ESC[2J ESC[1;1H` and the process exits 0;
   - (d) the arm's refusal log is empty, or lists only rows marked `refused-by-design`;
   - (e) a QEMU `screendump` taken mid-run matches a reference rendering of frame *i*
     (VGA text or fbcon) within a pixel tolerance.
4. The L1 `strace -f` trace of this run is filed as the row list for DoD-2 (Appendix C.2).

**M4 acceptance for the stand-in (fixed 2026-10-18, 20:35 CEST, before any L2 run).** M4 makes
T-CYB concrete for the arm that passed M3 (Unikraft 0.21 + app-elfloader + `koruext2fs` root,
TCG only). The parameters and checks below are frozen before measuring; a run passes only if
every gated item holds, and M4 passes only with 3/3 runs.
- **Program under test.** `/bin/ascii-animator` is the **STAND-IN**: a 100-line Rust `main.rs`
  around the plex-libs `anim.rs` decoder (copied verbatim, sha256 `9b671ec2…`), built as a
  static-PIE for `x86_64-unknown-linux-musl`. Its first output line names it `STAND-IN`, and
  every frame carries a `STAND-IN frame i/N` trailer line. It is not boot-animator.
- **Asset.** `/assets/80x24.anim` is plex-os `assets/boot.anim` (sha256 `b7de2964…`, 175 frames,
  24 fps, frames 240 columns wide) re-cut to the leftmost 80 columns × 24 rows, which is the
  window plex-os `cyberboot.rs` paints on its 80-column VGA screen. The re-cut is needed for a
  second reason too (V): `anim.rs` parses `# FPS:` and `# FRAME` markers, while `boot.anim`
  uses `fps:` and `[FRAME_n]`. Fed unchanged, `anim.rs` would see one 4,377-line frame.
  Neither the asset nor `anim.rs` is committed; both are copied from the pinned plex-shell
  checkout at build time and checked against their sha256.
- **Init.** The kernel command line runs `/bin/busybox sh /etc/t-cyb-init` (hush). The script
  starts `ascii-animator &`, runs `sleep 3` (k = 3 s of guest time, nominally 72 frames), sends
  `kill -USR1`, `wait`s, prints `t-cyb-init: ascii-animator exit status S`, and exits with S.
- **Gated checks** (lettering follows T-CYB):
  - (a) the serial log contains `Detected TTY size: 80x24`. The run records which source gave
    the size (`TIOCGWINSZ`, `$COLUMNS/$LINES`, or the 80×24 default). A default is acceptable
    for M4 but is reported, because boot-animator proper reads `TIOCGWINSZ`.
  - (b) at least n = 24 frame bodies appear, each byte-identical (after dropping `ESC[H`,
    `ESC[K` and CR) to the corresponding re-cut asset frame, with trailers 1, 2, 3, … strictly
    consecutive from frame 1, i.e. in asset order with no frame skipped or corrupted.
  - (c) after the signal the raw log contains `ESC[2J ESC[1;1H` followed by the stand-in's
    `SIGUSR1 after … exit 0` line; `t-cyb-init` reports exit status 0; the unikernel reports
    `init exited with status 0`.
  - (d) the refusal log is empty or lists only rows classified `refused-by-design`. On this
    arm the refusal log is the set of `-ENOSYS` returns of the syscall shim, made visible by
    a local patch that logs each one at error level as `koru-os: ENOSYS <name>`. A row is
    `refused-by-design` only if the program's observable behaviour is unaffected (for
    example a probe with a documented fallback), with the reason written down; any other
    row fails the run. *Amended 2026-10-19, before any acceptance run:* the first trial
    boot showed that `clock_nanosleep(CLOCK_MONOTONIC)` was a stub that returned 0 without
    sleeping (B10), a refusal that reports success and so never reaches the `-ENOSYS` log.
    The refusal log therefore also includes every `UK_WARN_STUBBED` call site, logged once
    as `koru-os: STUBBED <symbol>()`, and those rows are classified the same way.
    The classified rows live in `experiments/m4-cyb/refused-by-design.txt`.
  - (x) no `Unikraft Crash`; the disk image is byte-identical before and after the boot; the
    host `e2fsck -fn` stays clean.
- **Not gated in M4: (e).** The display path on this arm is the serial console plus Unikraft
  `vgacons`, which writes bytes into VGA text memory as CP437 cells and has no UTF-8 decoding.
  The asset is UTF-8 shade blocks (`░▒▓█`). A screendump would therefore show mojibake, and
  matching it against a rendering of frame *i* would test the encoding mismatch, not the
  program. A screendump is taken mid-run and kept on the box as evidence (screendumps are not
  committed). (e) stays **open** until a display path that decodes UTF-8 exists (fbcon or
  virtio-gpu, Q16), and M4 is reported as "(a)–(d) pass, (e) open", never as a full T-CYB pass.
- **L1 first.** The same binary and asset run on the build host (Linux 6.12.94+, the box) with
  `SIGUSR1` after 1 s under `strace -f`. The syscall histogram is filed with the evidence as the
  stand-in's DoD-2 row list.

### 0.3 Per-item mapping

**DoD-1: real filesystem.**
- **Arm.** L2. The FS is reached through Unikraft `vfscore`. There are two driver
  routes, and either satisfies DoD-1:
  - (a) an ext2 driver bound directly under vfscore;
  - (b) a **blk/fs driver silo** (§0.6) running LKL's ext4 over the `blk.*` rows,
    exposing `fs.*` rows to vfscore.

  9P to the host stays as a bridge (`koru-libs unikraft/ninep`) but does not satisfy
  DoD-1, because the host allocates the blocks.
- **Exists (V/C):**
  - `koru-libs/unikraft/blk` lifts `ukblkdev`: 18 exported functions, an eight-state
    ratchet, and phantom obligations. Its README (C) reports a QEMU boot demo that
    reads and writes a sector over `virtio-blk-pci`. This author did not reproduce it.
  - `koru-libs/unikraft/store` and `pages`/`vmem` exist (V, names only).
  - The KolibriOS kernel has FAT/ext2 code (`kernel/trunk/fs`, C: listing only, asm,
    GPL-2.0). It is a design donor, not a code donor (§4.1).
- **Missing:**
  - There is no `vfs`/`vfscore` lift in koru-libs (V: absent from the tree).
  - No ext2 or FAT driver for Unikraft was found by this author. Mainline `vfscore`
    names ramfs, 9pfs and devfs. Whether an ext2/ext4 port such as lwext4 exists is
    unknown (Q16).
  - There is no block allocator under koru obligations.
  - The box lacks `e2fsprogs`, `dosfstools`, `mtools` and `strace` (V: `which` empty).
    They are needed as oracles.
- **Rows.** About 20 `fs.*` identities: `openat`, `read`, `pwrite64`, `fsync`,
  `getdents64`, `statx`/`newfstatat`, `renameat2`, `unlinkat`, `mkdirat`,
  `ftruncate`, `fallocate` (refusable). They bind to vfscore ops, which bind to the
  ext2 driver, which binds to `unikraft/blk` transfers (Appendix C.1).

**Unikraft 0.21.0 core library list (V, as pulled by kraft 0.12.15, 2026-10-18).**
- **Filesystems:** `vfscore`, `ramfs`, `9pfs`, `devfs`, `ukfs-ramfs`, `ukfs-devfs`,
  `ukfs-virtiofs`, plus `drivers/virtio/fs`. There is **no ext2/ext4 or FAT** in the
  core tree. `virtiofs` is a host bridge like 9P and does not satisfy DoD-1. Whether an
  external lib provides ext or FAT is still open (Q16).
- **Other relevant libraries:** `posix-tty` (serial and tty), `drivers/input/ukps2`
  (PS/2 only), and `syscall_shim`, `posix-process`, `posix-futex`, `posix-poll`,
  `posix-eventfd`, `posix-timerfd`, `posix-unixsocket`, `posix-mmap`.
- **Absent:** no virtio-gpu and no virtio-input driver.

**M2 route decision (2026-10-18, about 19:55 CEST).** The minimal ext2 driver is a
Koru lift over `ukblkdev` (`koru/ext2`). Reasons:
- No `unikraft/lib-lwext4` is reachable. Upstream lwext4 @ `58bcf89a` is GPL-2.0 by
  default, so under R-SILO-1 it could only run inside a silo.
- `unikraft/lib-fatfs` is an empty initial commit.
- The LKL silo (DS1) needs a Unikraft host port that does not exist (Q25).

The lift allocates real inodes and blocks, and the host's e2fsck and debugfs accept the
result. It is deliberately narrow: one file, one group, direct blocks, and no vfscore
yet. vfscore integration is the next step for M3.

*Update 2026-10-18, about 20:30 CEST:* the read path is now a vfscore filesystem,
`lib/koruext2fs`. It has an allocation-free Zig core with a C ABI plus a C vnops glue,
and it is host-tested against `mke2fs -d` images in six geometries. It carries the M3
acceptance (`experiments/m3-ext2root/`). The writer is still the Koru lift; merging
the two parsers is debt.

**DoD-2: real shell and real programs.**
- **Arm.** L2 (`app-elfloader`), reference L1.
- **Exists (C, Unikraft docs and catalog):**
  - `app-elfloader` runs unmodified static and dynamic Linux ELF binaries through
    `syscall_shim`, with an strace-like debug option.
  - `posix-mmap` (anonymous and file mappings, `MAP_FIXED`/`SHARED`/`PRIVATE`).
  - `posix-futex` and `epoll*`/`poll`/`select`/`eventfd` (v0.10.0).
  - `posix-process` with multithreading, plus pipes, timerfd, Unix sockets and
    `uksignal`.
  - The upstream Node.js catalog Kraftfile enables all of these. This author built none
    of them.
- **koru side (V):**
  - `unikraft:image` and `unikraft:kconfig` emit a Kraftfile and Makefile.uk, with the
    Kconfig passed through, not derived.
  - BUILD.md (C) reports an ELF-loader image of 1,785,736 B with a 5 MB floor
    (macOS/arm64, TCG).
- **Missing / risk:**
  - `fork()` semantics in a single-address-space unikernel are unknown. Shells fork,
    and `posix_spawn`/`vfork` may suffice for `ash` with job control off (Q19). *2026-10-19 18:20: no POSIX fork; the process model is Spawn (§8.6).*
  - A tty line discipline is needed (canonical mode, `termios`, `TIOCGWINSZ`, job
    control signals).
  - `/bin/ascii-animator` is missing (Q18).
- **Rows.** `proc.*`, `sig.*`, `tty.*`, `mm.*` and `ev.*` groups (Appendix C.2), taken
  from the T-CYB and busybox traces.

**DoD-3: Hyprland plus a terminal.**
- **Arm.** L2/L3 with a **GPU driver silo** and an **input driver silo** (§0.6). L1 only
  produces the reference trace.
- **Stack (C, Hyprland CMake/pkg-config as published; Debian lists Hyprland 0.56.2):**
  - the hypr libraries: aquamarine (DRM/KMS and libinput backend), hyprutils,
    hyprlang, hyprcursor, hyprgraphics, hyprwire;
  - display and input: libdrm, gbm and EGL/GLES (Mesa), libinput ≥ 1.28, libseat
    (seatd or logind), libudev, xkbcommon, wayland-server and wayland-protocols;
  - rendering and fonts: pixman, cairo/pango;
  - other libraries: re2, muparser, Lua 5.5 (0.55+), glib/gio;
  - optional: XWayland.
- **Terminal choice.** foot renders on the CPU with pixman into `wl_shm` buffers
  (C), so it adds no GL demand of its own. kitty and alacritty need OpenGL. **foot is
  the DoD-3 terminal.**
- **Exists in koru:** nothing on the graphics path. `koru-libs/metal` is Apple
  Metal/AppKit (V). `koru-libs/vaxis` is a terminal UI library (V) and could later run
  *inside* foot.
- **Missing for any non-L1 arm.** All of these are D:
  - a GPU driver inside a silo. The candidates are LKL `virtio_gpu` on
    `virtio-gpu-pci` (?, Q25) and KolibriOS `vmwgfx` on QEMU `vmware-svga` (?, Q26).
    KolibriOS has no virtio driver (V);
  - the DRM/KMS uAPI on `/dev/dri/card0` and `renderD128`: dumb buffers, GEM, PRIME
    fd export, atomic modesetting, vblank events readable through `epoll`;
  - evdev on `/dev/input/event*` from virtio-input, with `EVIOCG*` ioctls;
  - udev-compatible enumeration (`/sys/class/drm`, `/sys/class/input`,
    `/run/udev/data`, and a netlink `uevent` or a static seed);
  - a seat, either seatd with `libseat` or a "builtin" seat;
  - `memfd_create` plus `F_ADD_SEALS`, `SCM_RIGHTS`, `timerfd`, `signalfd`;
  - Mesa: llvmpipe/`kms_swrast` (software) first, virgl via `virtio-gpu-gl` later.
- **Box limits (V):**
  - QEMU 10.0.13 offers `virtio-gpu-pci`, `virtio-gpu-gl-pci`, `virtio-vga(-gl)`,
    `virtio-keyboard/mouse/tablet-pci` and `-display egl-headless|none`.
  - `/dev/kvm` is accessible to the box user since 2026-10-18 13:10 CEST (V), so guests can run with `-enable-kvm`.
  - Guest GL is still software (llvmpipe) until virgl is wired. Frame rates are unmeasured.

**DoD-4: declarative UI.**

- **Ruling (Fabian, DRAFT 5).** QML is one example of declarative UI. It is the
  **canonical exemplar** for DoD-4. HTML fragments and components (for example
  "liquid"/glass-style components) are **separate tracks** and are not part of DoD-4.
  The design later integrates Fabian's `agents-design`, which today exists only as prose
  on his PC and is not available to this author (open item, Q23).
- **Arm.** Same as DoD-3.
- **QML in the Hyprland ecosystem (C; verified 2026-10-18, partly contradicting the
  brief).**
  - The Hyprland compositor does not depend on Qt. A hyprwm-affiliated maintainer
    (outfoxxed, Hyprland issue #8850) says so: Qt comes in through helper utilities
    and dialogs.
  - `hyprland-qt-support` is a Qt 6 QML style provider (Qt6 Qml/Quick/QuickControls2).
  - `hyprland-qtutils` (Qt/QML) is superseded by `hyprland-guiutils`. Whether
    guiutils still uses Qt or the hyprwm `hyprtoolkit` is unconfirmed (?).
  - So "practically required" holds for the ecosystem's dialogs and for QML shells,
    not for the compositor.
- **quickshell (C, quickshell.org; docs v0.2.0).**
  - A Qt Quick/QML toolkit for bars, widgets, lock screens and display managers.
  - Hot reload; layer-shell surfaces.
  - A `Quickshell.Hyprland` module: workspaces, monitors, toplevels and `dispatch`
    over Hyprland's `.socket.sock` and `.socket2.sock`.
  - Its site shows a configuration by vaxry.
  - Upstream says it still takes breaking changes.
- **noctalia (C, noctalia-dev/noctalia-shell, MIT, docs.noctalia.dev).** Noctalia
  **v4** was quickshell-based. The current **v5** is a native Wayland/OpenGL ES shell
  "with no Qt or GTK dependency" and a TOML configuration. v5 is a fresh install, not an
  upgrade from v4. Noctalia therefore no longer counts as evidence for QML. It is a
  useful second DoD-4 witness, a non-QML layer-shell client on Hyprland. Pinning v4 is
  an option if a quickshell-based noctalia is wanted.
- **Exemplar test.** A quickshell bar (Qt 6 QtQuick + QtWayland, plus
  fontconfig/freetype/harfbuzz/ICU, C) is the acceptance surface. Qt 6 widens the
  `mm.*`/`fs.*`/`ev.*` rows (Appendix C.3).
- **Koru-native track (D).** A Koru declarative UI that emits layer-shell surfaces
  through a small Wayland client, later shaped by `agents-design`. It is not a DoD gate.

### 0.4 Milestone ladder

Each milestone has an acceptance test that runs in QEMU on the box (TCG), produces a
serial log and, where graphical, a QMP `screendump` (PPM). The "L1 first" column
means the test is first run against a Linux guest to produce the expected trace.

| M | slice | arm | acceptance test (pass condition) | status |
|---|---|---|---|---|
| M0 | cyberboot on bare metal | plex-os i686 | serial shows `plexus_boot.anim` frames, then `plex-os>` | **M** (`plexos-serial.log`) |
| M1 | Koru-built Unikraft image reads and writes a sector | L2 native (koru-libs `unikraft/blk`) | guest writes pattern *P* to sector *s*; host `cmp` of `disk.img` at *s* equals *P*; serial shows the read-back bytes | **M (TCG), 2026-10-18**: 3/3 runs pass host `cmp`, image 194,176 B, 0.24–0.26 s wall (`experiments/m1-blk/`) |
| DS0 | silo contract and refusal harness | L2 | a silo with an empty row manifest boots. Every call into it is refused and logged as `refused: <identity> silo=<id>`. A call with a forged or expired handle is refused. The host-side log check finds no `ENOSYS` without a refusal entry | host model **M** (5/5 zig tests); **in-image M (TCG)**: `koruos/silo` Koru lift, 3/3 runs equal `expected.txt`; compile gates reject call-unbound, call-after-revoked, bind-twice (KORU030); leaks are auto-discharged by koruc, not rejected (`experiments/ds0-silo/`) |
| DS1 | LKL blk/fs silo | L2 + silo:lkl (host ops on Unikraft, Q25) | silo mounts ext4 from virtio-blk via `blk.*` rows and exposes `fs.*`; DoD-1 test (M2) passes through it | D |
| M2 | real FS allocates blocks (**DoD-1**) | L2: vfscore + ext2 driver, **or** DS1 | guest creates `/dod1` of *N* blocks, writes, `fsync`s, halts; host `e2fsck -fn` clean, `debugfs -R 'cat /dod1'` equals pattern, free-block count dropped by ≥ *N* | **M (TCG), 2026-10-18**: minimal ext2 Koru lift (`koru/ext2`); 3/3 + 1 runs pass, e2fsck exit 0, free blocks −10, inodes −1 (`experiments/m2-ext2/`). Scope of the writer: one file, one group, direct blocks. Read path under vfscore since 2026-10-18 (`lib/koruext2fs`, host oracle 7/7; B7 closed) |
| M3 | static busybox shell from the ext root | L2 `app-elfloader` (L1 trace first) | scripted serial session: `echo`, `ls /`, `cat /dod1`, `exit 3` → exit status 3 observed; refusal log empty or only by-design rows | **M (TCG), 2026-10-18, PASS 3/3**: M2 guest writes `/dod1` into an `mke2fs -d` busybox image, host `e2fsck -fn` clean; M3 guest mounts it through `koruext2fs` (vfscore, read-only) as `/` and runs `ls /`, `cat /dod1` (guest sha256 = pattern), a pipeline, `exit 3` → "init exited with status 3"; boot to exit 0.39–0.42 s wall (`experiments/m3-ext2root/`). Refusal-log clause N/A (no silo in this image). Fixed on the way: B6 (vfork FSBASE, empty argv), virtio ring destroy under LIBUKVMEM. Debt: root is read-only; `koru/ext2` (writer) and `ext2core.zig` (reader) duplicate parsing |
| M4 | **T-CYB** (§0.2) | L2 (L1 trace first) | (a)–(d) gated, (e) open; frozen parameters in §0.2 "M4 acceptance for the stand-in" | **M (stand-in): (a)–(d) PASS 3/3 under TCG, 2026-10-19 12:55 CEST; (e) open** (`experiments/m4-cyb/README.md`); needed fixes B9, B10. Full T-CYB still waits for boot-animator (Q18) and a UTF-8 display path |
| M5 | real programs, dynamic linking (**DoD-2**) | L2 | musl, then glibc, `ld.so` run coreutils and an interactive `ash` with a pipeline (`ls \| wc -l`); T-CYB still passes | **M5a (M): PASS 3/3 under TCG, 2026-10-19 13:06 CEST**: musl and glibc `ld.so`, GNU coreutils 9.7, dynamic busybox shell pipeline; M3 and M4 regressions 3/3 on the same kernel (`experiments/m5-dyn/README.md`); needed fix B12. Open: musl-built busybox, `dlopen`, threads, `fork` (Q19) |
| DS2 | Kolibri driver silo, first driver | L2 + silo:kolibri (KolibriOS driver-service personality) | an unmodified KolibriOS `.sys` network or input driver (`RTL8139`/`pcnet32` on QEMU `rtl8139`/`pcnet`, or `ps2mouse4d`) loads in the silo. Its imports either bind to rows or are refused by name. `net.*` frames or `input.*` events cross the silo boundary (serial log) | D |
| DS3 | GPU driver silo | silo:lkl `virtio_gpu` on `virtio-gpu-pci`, or silo:kolibri `vmwgfx` on `vmware-svga` | the silo exposes only the `kms.*` rows of Appendix C.3; M6 passes through it | D |
| DS4 | input driver silo | silo:lkl `virtio_input` (evdev) or silo:kolibri `usbhid`/`ps2` translated to `input.*` | M7 passes through it | D |
| M6 | KMS scanout of a dumb buffer | L2 + DS3 (L1 trace first); M6 uses a native provider instead ("M6 decision" below, Q28) | libdrm `modetest -s <conn>:<mode>` (or equivalent) draws a test pattern; screendump pixel check at known coordinates; frozen parameters in "M6 acceptance" below | **M (native provider): PASS 3/3 under TCG, 2026-10-19 13:36 CEST**: `kmsdumb` (raw ioctls, two dumb buffers, two `SETCRTC`) and unmodified libdrm `modetest -M korukms -s Virtual-1:1024x768`; all three screendumps 0 of 786,432 pixels off the independent references, and byte-identical to the L1 `bochs-drm` twin; M3/M4/M5a regressions 3/3 (`experiments/m6-kms/README.md`). Not through DS3 (Q28); no atomic, properties or vblank events yet |
| M7 | input | L2 + DS4; M7 uses a native provider instead ("M7 decision" below, Q28) | QMP `input-send-event` key events appear in `libinput debug-events` on serial; split into M7a (evdev uAPI) and M7b (libinput) | **M7a PASS 3/3** (13:57). **M7b PASS 3/3 under TCG, 2026-10-19 15:07 CEST**: unmodified Debian `libinput debug-events --device /dev/input/event0` (1.28.1) over the kernel sysfs view (`lib/korusysfs`) and libudev-zero; 18 KEYBOARD_KEY lines = derived = L1 (udevd and libudev-zero twins); M3/M4/M5a/M6/M7a/M8a/M8b regressions 3/3 (`experiments/m7b-libinput/README.md`). B15 resolved. Not through DS4 (Q28) |
| M8 | GL on KMS | L2 + DS3 + Mesa llvmpipe/`kms_swrast` in userspace | `kmscube` runs; two screendumps 1 s apart differ, and both are non-black; split into M8a (offscreen EGL/GBM, frozen in "M8a acceptance") and M8b (kmscube) | **M8a: PASS 3/3 under TCG, 2026-10-19 14:15 CEST**: unmodified Mesa 25.0.7 llvmpipe (LLVM 19.1.7) renders offscreen via EGL surfaceless and via EGL on GBM over `/dev/dri/card0`; frame hashes equal the L1 twin's, probe pixels as derived (`experiments/m8-gl/README.md`). **M8b: PASS 3/3 under TCG, 2026-10-19 14:26 CEST**: unmodified Debian `kmscube` on `/dev/dri/card0` (GBM surface, `kms_swrast`/llvmpipe, legacy page flips with flip events), 149 frames at 13–14 fps, two screendumps 1 s apart differ in ~206,000 of 1,024,000 pixels, cube visible; L1 `bochs-drm` twin alike at ~20 fps; M3/M4/M5a/M6/M7a/M8a regressions 3/3 on the M8b kernel. Native KMS provider, not DS3 (Q28); no vblank pacing |
| M9 | **DoD-3**: Hyprland + foot | L2 + native `bochs-display` and i8042 providers (Q28 closed 15:55: native first; DS3/DS4 as a later milestone of their own) | screendump shows a foot window; QMP keys type `echo DOD3 > /tmp/dod3`; `hyprctl -j clients` lists class `foot`; after shutdown the host reads `/tmp/dod3` from the image | **counted 17:43–17:47 CEST: not passed as frozen**: (h1), (h2b), (h3), (h4), (h5), (x) 3/3; (h2a) `hyprctl dispatch exec foot` fails 3/3 (no fork, B20). **M9 open** (Q29 ruled 18:20: not passed, (h2) not amended; met only via Spawn, §8.6, Q30). foot runs as a window via `foot --pty` + `lib/korupty` (B21); regressions M3–M8b and M7b 3/3 on the M9 kernel |
| M10 | **DoD-4**: QML exemplar | same as M9 | a quickshell bar on a layer-shell surface is visible in a screendump; editing its QML changes the next screendump without a restart | D |

Every row above has an **L1 twin run** that produces the reference trace and
screendumps. That twin is filed as oracle evidence and is never counted as a pass.

Order of risk: M2 and M3 are bounded engineering. M5 is gated by `fork` (Q19; closed 2026-10-19: DoD-2 is reformulated only after Spawn-lib acceptance). DS1 and
DS3 are gated by the LKL host port onto Unikraft and by device access from inside a
silo (Q25). DS3 is the largest item in this note, and its size is unknown.

**Architectural priority vs the DoD ladder (2026-10-19 about 18:35 CEST).** *Folded in 2026-10-19 about 18:35 CEST from Fabian's second paste (authoritative guidance; the wording here is this note's).*

- The **next architectural priority** is the vertical slice (§11, Slice A in §11.4) and the
  realization graph (§11.0).
- Hyprland/M9 remains **DoD-3 evidence on the Linux-ABI arm (L2)**. It is not the first
  architectural object, and a compositor is one renderer of the session (§7).

This is a real tension: the ladder M0–M10 was ordered by DoD risk, and M9 has absorbed most of
the recent work (Unikraft patches, korupty, Spawn §8.6 for (h2)). The two meet in Spawn: Slice A's
supervisor (S13) and M9's `dispatch exec` both need the child record. Building Spawn for the slice
first would serve both.

How to order the two is Q37. Until Fabian rules:

- M9 stays open (Q29);
- Q30 stays open;
- no M9 work is counted.

**M5a acceptance: dynamic linking (fixed 2026-10-19, 13:02 CEST, before any acceptance run).**
M5a is the first half of M5. It runs on the M3/M4 arm (Unikraft 0.21 + app-elfloader +
`koruext2fs`, TCG only). It proves that app-elfloader's `PT_INTERP` side-load runs real
dynamically linked programs from the ext2 root, under both dynamic loaders. Probes before
this freeze found B12: every `execve()`d program got a 64 KiB stack, and GNU `wc` overflowed
it. The arm is therefore rebuilt with `CONFIG_STACK_SIZE_PAGE_ORDER=7` (512 KiB).
- **Image.** The init shell is `/bin/busybox` 1.37.0 built as a **dynamically linked** glibc
  PIE, the same config as M3 minus `-static-pie`. The image also holds:
  - `/lib64/ld-linux-x86-64.so.2`, plus `libc.so.6`, `libm.so.6`, `libresolv.so.2`,
    `libselinux.so.1`, `libcap.so.2` and `libpcre2-8.so.0` from the build host (Debian 13,
    glibc 2.41);
  - `/lib/ld-musl-x86_64.so.1` (Debian musl 1.2.5);
  - GNU coreutils `ls`, `wc`, `sha256sum`, `sort` and `head` from the build host, under
    `/usr/bin`;
  - two small test programs, `hello-musl` and `hello-glibc` (dynamic PIE);
  - a data file `/etc/m5-data`.

  Nothing in the image is committed.
- **Session.** The kernel runs `/bin/busybox sh` interactively on the serial console. A
  scripted session types each command after an `echo M5-Tn` marker; `exit 5` ends it.
- **Gated checks.** Expected values are computed on the host from the same files.
  - (m1) musl: `hello-musl a b` prints its line with `argc=3`, and the shell sees exit
    status 42;
  - (m2) glibc: `hello-glibc a` prints its line with `argc=2`, and the shell sees 42;
  - (m3) GNU `ls /` lists exactly the host's `ls -1` of the image root;
  - (m4) GNU `ls / | wc -l` prints the host count;
  - (m5) the dynamic busybox shell runs a pipeline of dynamic busybox applets:
    `ls / | wc -l` prints the same count;
  - (m6) GNU `sha256sum /etc/m5-data` equals the host hash;
  - (m7) GNU `sort /etc/m5-data | head -3` equals the host output;
  - (m8) `exit 5` is reported as `init exited with status 5`;
  - (d) every refusal-log row is in `experiments/m5-dyn/refused-by-design.txt` (rule as
    in M4);
  - (x) no `Unikraft Crash`; the disk is byte-identical before and after; `e2fsck -fn`
    stays clean.
- **Regression.** M3 acceptance and M4 (a)–(d) each pass 3/3 on the same kernel.
- **Out of scope for M5a.** A musl-built busybox, `dlopen`, threads, and the remaining
  DESIGN M5 wording (an `ash` with `fork`; hush is NOMMU/vfork, Q19).

**M6 decision: where the KMS driver lives (2026-10-19, 13:34 CEST).** The table above names
"L2 + DS3" for M6. M6 instead binds the `kms.*` rows to a **native koru-os provider** for
QEMU `bochs-display` (`lib/korukms`), and DS3 stays open. The reasons, against §0.6:
- §0.6 governs *foreign* driver code: Linux (LKL) and KolibriOS drivers enter only as silo
  personalities, never in the core (R-SILO-1). A koru-os driver written from the device's
  register layout is not foreign code. M2 set the precedent ("vfscore + ext2 driver, **or**
  DS1"): the native path proves the rows, and the silo path re-binds the same rows later.
- The contract that M7–M10 depend on is the `kms.*` row set and the Linux DRM uAPI above it,
  not the provider. `lib/korukms/kms_rows.h` is that seam. DS3 replaces `bochs.c` with a
  silo membrane; the DRM personality, the programs and the tests do not change.
- DS3 is the largest unknown in this note (Q25: an LKL host port onto Unikraft, PCI/IRQ/DMA
  from inside a silo). Gating every graphics milestone on it first would leave M7–M9
  untestable for an unknown time.
- `virtio-gpu` natively was rejected for M6: the Unikraft 0.21 virtio-pci driver is legacy
  only (V, `drivers/virtio/pci/virtio_pci.c`), and virtio-gpu is a virtio 1.0 device.
  `bochs-display` is a linear framebuffer with 10 DISPI registers, so the provider is about
  300 lines and every line can be read against QEMU's device model.
- Whether DoD-3 ("drivers in driver silos", §0) accepts a native koru provider for the GPU,
  or requires DS3, is Fabian's call (Q28). Until he rules, M9 is reported as "native KMS
  provider", never as "through DS3".

**M6 acceptance: KMS scanout of a dumb buffer (fixed 2026-10-19, 13:34 CEST, before any
acceptance run).** Probe boots before this freeze found and fixed: the posix-mmap hook symbol
was localized by `exportsyms.uk` (mmap fell back to the file VMA, `EOPNOTSUPP`), and devfs
readdir listed the root inside `/dev/dri`. The L1 twin ran once before the freeze (below).
- **Arm.** The M5a arm (Unikraft 0.21 + app-elfloader + `koruext2fs` root, B6/B8/B9/B10/B12
  and the refusal log) plus `lib/korukms` and two patches
  (`experiments/m6-kms/patches/`: devfs one-level subdirectories with `st_rdev`; the
  posix-mmap device-memory hook). QEMU `-vga none -device bochs-display` (16 MiB VRAM),
  TCG only.
- **Programs.** Both run from the ext2 root under the M3 hush (`/etc/m6-init`), dynamically
  linked against glibc 2.41:
  - `/bin/kmsdumb` (koru-os test, raw DRM ioctls, no libdrm): finds the connector and the
    1024×768 mode, creates two XRGB8888 dumb buffers, maps them with `mmap()`, fills pattern A
    and pattern B (`experiments/m6-kms/kmsdumb.c`), scans out A (`SETCRTC`), then B, then probes
    `DRM_CLIENT_CAP_ATOMIC`, removes the fbs and buffers, exits 0;
  - `/usr/bin/modetest` from Debian `libdrm-tests` 2.4.124, unmodified, with Debian
    `libdrm2` 2.4.124: `sleep 4 | modetest -M korukms -s Virtual-1:1024x768` (the libdrm SMPTE
    pattern in a dumb buffer, legacy `SETCRTC`, waits for stdin EOF, tears down).
  Nothing of this is committed except `kmsdumb.c`.
- **Screendumps.** The host takes a QEMU monitor `screendump` 1 s after each marker line
  (`kmsdumb: PHASE A`, `kmsdumb: PHASE B`, modetest's `setting mode`) appears on the serial log.
- **Gated checks.** Expected frames come from `expected.py`, which renders pattern A, pattern B
  and libdrm's `fill_smpte_rgb32` independently of the guest.
  - (k1) kmsdumb reports a connected connector of type 15 (Virtual) with a 1024x768 mode and
    two dumb buffers with fb ids, and prints `kmsdumb: done, exit 0`;
  - (k2) the PHASE A screendump is 1024×768 and equals pattern A with **0** mismatched pixels;
  - (k3) the PHASE B screendump equals pattern B with 0 mismatched pixels (a second `SETCRTC`
    re-points scanout);
  - (k4) modetest prints `setting mode 1024x768-60.00Hz on connectors Virtual-1, crtc 32`,
    its screendump equals the SMPTE reference with 0 mismatched pixels, and m6-init reports
    `modetest exit status 0`;
  - (k5) refusal is loud: kmsdumb's atomic probe returns `-1` with errno 95 (`EOPNOTSUPP`), and
    the log has `REFUSED linux.ioctl.DRM_IOCTL_SET_CLIENT_CAP cap 3 (kms)`. Every refusal-log
    row (`ENOSYS`, `STUBBED`, `REFUSED`) is in `experiments/m6-kms/refused-by-design.txt`
    (rule as in M4);
  - (k6) `koru-os: init exited with status 0`;
  - (x) no `Unikraft Crash`; the disk is byte-identical across the boot; `e2fsck -fn` is clean.
- **Regression.** M3, M4 (a)–(d) and M5a each pass 3/3 on the M6 kernel (their own harnesses,
  without a display device).
- **L1 twin (oracle, not a pass).** The same `kmsdumb` and `modetest` binaries on Debian
  `linux-image-6.12.113+deb13-amd64` with `bochs-drm` (initramfs, TCG, `strace -f`), same
  screendump points and references (`run-l1.sh`). First run 2026-10-19 13:33 CEST: all three
  frames exact (0 mismatched pixels); ioctl histograms filed. Known, accepted differences:
  Linux serves properties (`GETPROPERTY` ×16 in modetest), two planes, 15 modes, accepts
  atomic, and implements legacy gamma.
- **Not in M6.** DS3 and R-SILO-4 (no silo yet), atomic KMS and properties, page-flip and
  vblank events, PRIME, cursor planes, virtio-gpu, more than one DRM client.

**M7 decision: where the input driver lives, and what M7 can claim now (2026-10-19, 13:55
CEST).** The table names "L2 + DS4" and `libinput debug-events`. M7 is split:
- **Provider.** As in M6, the `input.*` rows (`lib/koruinput/input_rows.h`) are bound to a
  **native koru-os provider**, here the i8042 PS/2 keyboard of the QEMU i440fx machine
  (`lib/koruinput/ps2kbd.c`), and DS4 stays open. The §0.6 reasoning of the M6 decision holds
  unchanged (native, non-foreign code; the rows are the seam; DS4 depends on Q25). DS4 itself
  names "silo:kolibri `ps2`" as one option, so PS/2 is a device the DoD already expects.
  `virtio-input` natively is unreachable for the same reason as virtio-gpu (B13: the Unikraft
  0.21 virtio-pci transport is legacy only; virtio-input is a virtio 1.0 device).
- **Personality.** Linux evdev on `/dev/input/event0` (char 13:64,
  `lib/koruinput/evdev_linux.c`): `read()` of `struct input_event`, `O_NONBLOCK`, poll/select/
  epoll readiness, the identity and bitmap ioctls, `EVIOCGRAB`, `EVIOCSCLOCKID`.
- **M7a**: the evdev uAPI (PASS). **M7b (PASS 15:07)**: the table's `libinput debug-events`,
  over a kernel-written sysfs view (`lib/korusysfs`) and **libudev-zero** as `libudev.so.1`
  (no udevd, no `/run/udev` database; B15 resolved, see "M7b acceptance"). systemd's libudev
  on koru-os is B16.
- Whether DoD-3 accepts native providers for GPU *and* input is the same question as Q28;
  Q28 now covers both.

**M7a acceptance: evdev key input (fixed 2026-10-19, 13:55 CEST, before any acceptance run).**
Probe boots before this freeze found and fixed: vfscore (legacy) epoll entries in
Unikraft 0.21 never set `epf`, so the first `eventpoll_signal()` from any vfscore driver
dereferenced NULL (patch `unikraft-0.21-posix-poll-legacy-epf.patch`, B14); the set 1 decoder
dropped `0xaa` (LeftShift break) as a BAT code; `MSC_SCAN` for 0xE0 keys now reports
`code | 0x80` as Linux `atkbd` does. The L1 twin ran once before the freeze (below).
- **Arm.** The M6 arm plus `lib/koruinput` and two patches (`experiments/m7-input/patches/`:
  devfs poll dispatch and `O_NONBLOCK` to device read; the posix-poll `epf` fix). QEMU
  i440fx with its i8042, `-vga none -device bochs-display`, TCG only. The host injects keys
  with QMP `input-send-event` (qcodes), one press/release chord every 0.4 s
  (`experiments/m7-input/drive.py`).
- **Programs.** From the ext2 root under the M3 hush (`/etc/m7-init`), glibc 2.41:
  - `/bin/evdump` (koru-os probe, `experiments/m7-input/evdump.c`): `O_NONBLOCK` read on the
    empty queue, identity and bitmap ioctls, the `EVIOCGRAB` sequence, `READY`, then
    `poll()` + `read()` until `KEY_ESC` is released. Host sequence: k, o, r, u, shift+1,
    enter, up, esc;
  - `/usr/bin/evtest` from Debian `evtest` 1.35, unmodified, `evtest /dev/input/event0`
    (select + read loop). Host sequence after `Testing ...`: a, b. The host then quits QEMU.
  Nothing of this is committed except `evdump.c`.
- **Gated checks** (`experiments/m7-input/check.py`):
  - (i1) `ls -l /dev/input` shows `event0` as a character device 13, 64;
  - (i2) evdump: `O_NONBLOCK` read returns `EAGAIN`; version 0x010001; bus 0x0011; EV bits
    exactly `SYN KEY MSC LED REP`; `KEY_A`, `KEY_ENTER`, `KEY_UP`, `KEY_ESC`,
    `KEY_LEFTSHIFT` set; `EVIOCGREP` 250/33; no key down; `EVIOCGRAB` 1 → 0, again →
    `-EBUSY`, 0 → 0, again → `-EINVAL`;
  - (i3) evdump's event list equals, triple by triple (type, code, value), the 54 events
    derived from the host sequence and the set 1 table in check.py (`MSC_SCAN`, `EV_KEY`,
    `SYN_REPORT` per press and release; shift is held across 1), and the summary is
    `keys 18 syns 18 msc 18 ... nonmonotonic 0 esc yes`, exit status 0;
  - (i4) evtest prints `Input driver version is 1.0.1`, the device ID line
    `bus 0x11 vendor 0x1 product 0x1 version 0xab41`, lists `EV_KEY` with `KEY_ESC`, then
    after `Testing ...` exactly these 12 events in order (6 per key) (`MSC_SCAN 1e`,
    `KEY_A 1`, `SYN`, `MSC_SCAN 1e`, `KEY_A 0`, `SYN`, same for `30`/`KEY_B`);
  - (i5) every refusal-log row is in `experiments/m7-input/refused-by-design.txt`;
  - (i6) the close statistics line reports 0 dropped events and 0 ring drops;
  - (x) no `Unikraft Crash`; the disk is byte-identical across the boot; `e2fsck -fn` clean.
- **Regression.** M3, M4 (a)–(d), M5a and M6 each pass 3/3 on the M7 kernel.
- **L1 twin (oracle, not a pass).** The same `evdump` (under `strace`) and `evtest` binaries on
  Debian `linux-image-6.12.113+deb13-amd64` (i8042 and `atkbd` built in, `evdev.ko`), the same
  `drive.py` (`run-l1.sh`). First run 2026-10-19 13:52 CEST: all 54 evdump triples and the
  evtest event lines as in (i3)/(i4). Known, accepted differences: name
  `AT Translated Set 2 keyboard`; `atkbd` declares 145 key codes (set 2 table with media keys),
  koru-os 107 (set 1 make codes 0x01–0x58, the 0xE0 navigation block, Pause); Linux ioctls
  return byte counts where koru-os returns 0 (devfs ioctl returns an errno only; evtest and
  libevdev test `< 0`).
- **Not in M7a.** libinput (M7b, B15), DS4, the aux port (mouse), LED writes, software
  autorepeat, keymaps, more than one concurrent reader, `EVIOCGMASK`/`SMASK`, `EVIOCREVOKE`.

**M8a acceptance: offscreen GL through Mesa llvmpipe (fixed 2026-10-19, 14:15 CEST, before
any acceptance run).** The table's M8 criterion (`kmscube` on KMS, two screendumps that differ)
is **M8b** and stays open: kmscube needs a GBM scanout surface, `drmModePageFlip` with flip
events (`read()` and `poll()` on `/dev/dri/card0`), none of which the M6 personality serves yet.
M8a is the offscreen step: EGL + GLES2 + llvmpipe, first without any device (Mesa surfaceless
platform), then on the GBM platform over `/dev/dri/card0` (the native KMS provider), rendering
into an FBO only. No new kernel code: M8a runs on the **M7a kernel binary**
(`/workspace/m7kclean`, sha256 `68e7f446…`), whose M3/M4/M5a/M6 regressions and M7a runs
are already 3/3. Probe boots before this freeze found and fixed only harness errors (Mesa's
compiled-in `/usr/lib/x86_64-linux-gnu/{gbm,dri}` paths; GBM has no pbuffer configs).
- **Programs.** `/bin/gloff` (koru-os probe, `experiments/m8-gl/gloff.c`), glibc 2.41, glvnd
  1.7.0 `libEGL`/`libGLESv2`, Mesa 25.0.7 (`libEGL_mesa`, `libgallium`, `dri_gbm`,
  `kms_swrast`/`libdril`), LLVM 19.1.7, all unmodified Debian 13 binaries (`mkroot.sh`). Two
  frames of 256×256 RGBA8: clear (0.1, 0.2, 0.3) plus one RGB triangle, then the triangle
  rotated by 90°; `glReadPixels`, FNV-1a 64 hash and probe pixels. Run twice from
  `/etc/m8-init`: no argument (surfaceless), then `/dev/dri/card0` (GBM). QEMU `-m 1G`, TCG,
  `-cpu qemu64` (llvmpipe reports 128-bit vectors).
- **Gated checks** (`experiments/m8-gl/check.py`):
  - (g1) surfaceless: EGL 1.5 vendor Mesa Project, `GL_RENDERER llvmpipe (LLVM 19.1.7, …)`,
    `OpenGL ES 3.2 Mesa 25.0.7…`, FBO complete; frame hashes `9c784fad9c82cce9` and
    `5be5b6b059035ef9`, which are the L1 twin's (and the box host's), `glError` 0, exit 0;
  - (g2) independent of any oracle: both frames have the clear colour 26 51 76 255 at (0,0) and
    (255,255); frame 0 is red-dominant at (60,40) and green-dominant at (200,40); frame 1 is
    clear at (60,40) and red-dominant at (200,40) (the rotation moved the red corner);
  - (g3) GBM on `/dev/dri/card0`, backend `drm`: the same strings and the same two hashes;
  - (g4) every refusal-log row is in `experiments/m8-gl/refused-by-design.txt` (new:
    `memfd_create`, `sched_getaffinity` stub), and the only Mesa messages are
    `MESA-LOADER: failed to retrieve device information` (libdrm `drmGetDevice2` reads sysfs,
    B15) and `kmsro: driver missing` (also on L1: neither `bochs-drm` nor `korukms` is a
    render driver, so Mesa takes `kms_swrast`);
  - (g5) both gloff runs and init exit 0; (x) no `Unikraft Crash`, disk unchanged, `e2fsck` clean.
- **L1 twin (oracle, not a pass).** The same userland in an initramfs on Debian
  `linux-image-6.12.113` with `bochs-drm`, same `-cpu`, `strace -f -c` (`run-l1.sh`). First run
  2026-10-19 14:13 CEST: both runs produce the two hashes above. Differences: Linux serves
  `memfd_create` (2 calls) and sysfs; no clone in either (1 vCPU, no rasterizer threads).
- **Not in M8a.** M8b (`kmscube`, GBM scanout surfaces, page flip and its events), DS3,
  llvmpipe with rasterizer threads (needs a second vCPU), the Mesa shader cache
  (`MESA_SHADER_CACHE_DISABLE=true`), GL desktop profiles, virgl.

**M8b acceptance: `kmscube` on KMS (fixed 2026-10-19, 14:24 CEST, before any acceptance run).**
This is the table's M8 criterion. Probe boots before this freeze found: kmscube's legacy loop
`select()`s on stdin as well and quits when it is readable (the serial console always is), so
stdin is an idle pipe, as for modetest in M6; and the M6 personality had no page flip.
- **Arm.** The M7a arm with `lib/korukms` extended (`drm_linux.c`): legacy
  `DRM_IOCTL_MODE_PAGE_FLIP` with `DRM_MODE_PAGE_FLIP_EVENT`, `read()` of
  `DRM_EVENT_FLIP_COMPLETE` (whole 32-byte events, `O_NONBLOCK`), and poll/select readiness on
  `/dev/dri/card0` (through the M7 devfs poll patch). The flip takes effect at once and its
  event is queued at once: bochs-display has no vblank interrupt, so there is no 60 Hz pacing.
  Built by `experiments/m7-input/build-image.sh` with `W=/workspace/m8kclean`.
- **Program.** Debian `kmscube` 0.0.0~git20210103 unmodified (with its gstreamer and libpng
  dependencies from Debian 13), on the M8a GL userland (`mkroot.sh … <kmscube root>`):
  `sleep 25 | kmscube -D /dev/dri/card0 -c 150` from `/etc/m8b-init`, smooth-shaded cube on a
  GBM surface (`kms_swrast`, llvmpipe), legacy `SETCRTC` then one page flip per frame.
- **Screendumps.** `shots.py`: QMP `screendump` 1 s after kmscube's first `Rendered` line and
  again 1 s later.
- **Gated checks** (`experiments/m8-gl/check-m8b.py`):
  - (c1) EGL 1.5, vendor Mesa Project, renderer `llvmpipe (LLVM 19.1.7, …)`, `Using modifier`,
    at least 3 `Rendered` lines, the last one at 149 frames, exit status 0, and the personality
    reports 150 page flips at close;
  - (c2) both screendumps are 1280×800 (the EDID preferred mode, also chosen on L1), grey
    background 80 80 80 at (0,0), 5–50 % non-grey pixels (the cube), under 1 % black pixels,
    and the two differ in at least 1 % of the pixels (the cube turned);
  - (c3) every refusal-log row is in `refused-by-design.txt` (new: `ADDFB2` with
    `DRM_MODE_FB_MODIFIERS`, refused with `EINVAL` as on L1 `bochs-drm`; kmscube falls back);
  - (c4) the only Mesa messages are the two classified in M8a; (x) no crash, init exit 0, disk
    unchanged, `e2fsck` clean.
- **Regression.** The kernel changed (`drm_linux.c`), so M3, M4 (a)–(d), M5a, M6, M7a and M8a
  each run 3/3 on it.
- **L1 twin (oracle, not a pass).** Same userland, same command and `shots.py` on Debian
  6.12.113 + `bochs-drm` (`run-l1-m8b.sh`), first run 2026-10-19 14:24 CEST: the same mode and
  messages (`Modifiers failed!` too), 149 frames, (c2) holds on its screendumps; 150
  `pselect6` and 327 `ioctl` calls. Known difference: Linux paces flips to vblank and reaches
  about 20 fps, koru-os about 14 fps under the same TCG (not gated).
- **Not in M8b.** Vblank pacing and `DRM_IOCTL_WAIT_VBLANK`, atomic KMS, modifiers, DS3,
  multi-threaded llvmpipe.

**M7b acceptance: libinput on the koru-os sysfs view (fixed 2026-10-19, 15:07 CEST, before any
acceptance run; resolves B15).** Probe boots and the L1 oracle before this freeze established:
libinput's path backend (`--device`) touches only `/sys/dev/char/13:64`, the `uevent` files and
`subsystem` links along `event0 → input0 → serio0 → i8042 → platform`, `/run/udev/data/*` and
`/sys/devices/virtual/dmi/id` (strace on L1, `experiments/m7b-libinput/evidence/l1-debian/`); it
reads no capability attributes (bitmaps come from evdev ioctls). Debian's systemd `libudev.so.1`
on koru-os fails before any of that: its path resolution needs `statx` with `STATX_MNT_ID`,
`name_to_handle_at`, `O_PATH` symlink fds and `/proc/self/fd` (probe kept in
`evidence/probe-koru-debian-libudev/`, B16). Also found and fixed: vfscore's `newfstatat` ignored
`AT_SYMLINK_NOFOLLOW` for absolute paths, so glibc `lstat()` followed symlinks
(`unikraft-0.21-vfscore-fstatat-nofollow.patch`); set 1 code 0x54 now reports `KEY_SYSRQ` as
`atkbd` does (it was the non-code 84).
- **Decision: the udev-less path.** koru-os writes a minimal sysfs view and uses
  **libudev-zero** (ISC, pinned commit, `build-libudev-zero.sh`) as `libudev.so.1`: it reads
  `/sys` directly and derives `ID_INPUT_*` from the input device's uevent bitmaps, so there is
  no udevd and no `/run/udev` database. The libinput binaries and libraries stay Debian's,
  unmodified. systemd's libudev on koru-os is B16 (not needed for M7b; revisit if an M9
  component insists on it).
- **Kernel side.** `lib/korusysfs` mounts a ramfs on `/sys` (mount point in the image) at a
  late initcall and replays what was published: a **provider** publishes the nodes of its own
  hardware (`ps2kbd.c`: `platform/i8042/serio0`; `bochs.c`: `pci0000:00/0000:00:BB.F` with
  `vendor`/`device`/`class`/... from PCI config space) and names its node in the row
  (`input_provider.sys_parent`, `kms_provider.sys_parent`); a **personality** publishes the class
  device it creates under that node (`evdev_linux.c`: `input/input0` with the Linux
  `input_dev_uevent` lines and attributes, `input0/event0`; `drm_linux.c`: `drm/card0`, `device`
  link), plus `/sys/class/*`, `/sys/bus/*/devices/*`, `/sys/dev/char/M:m`. A driver silo would fill
  the same row fields; nothing here assumes the native providers (Q28 stays open).
- **Arm.** The M8b kernel plus `lib/korusysfs` and the fstatat patch (built by
  `experiments/m7-input/build-image.sh`), QEMU i440fx, `-vga none -device bochs-display`, TCG
  only, keys via QMP `input-send-event` (`experiments/m7b-libinput/drive.py`, after
  `DEVICE_ADDED`: k, o, r, u, shift+1, enter, up, esc).
- **Programs** (ext2 root, `/etc/m7b-init` under the M3 hush): `ls -lR /sys` and `head` of every
  file; `/bin/udevprobe` (koru-os probe, `udevprobe.c`: libudev view of event0 and card0 by
  devnum, parents, `drm`/`input` enumeration); then Debian `libinput-tools` 1.28.1, unmodified,
  `libinput debug-events --show-keycodes --device /dev/input/event0` (the host quits QEMU).
- **Gated checks** (`experiments/m7b-libinput/check.py`, against the L1 evidence committed in
  b1d02a9):
  - (b1) the kernel logs `sysfs view on /sys: N entries, 0 errors`; the `uevent` of `event0`
    and `card0`, the `subsystem` links of event0, input0, serio0, i8042, card0 and the PCI device,
    and the links `/sys/dev/char/13:64`, `/sys/dev/char/226:0`, `/sys/class/input/event0`,
    `/sys/class/drm/card0` equal L1's; input0's `PRODUCT`, `PHYS`, `PROP`, `EV`, `MSC`, `LED`
    equal L1's, its `KEY` bitmap is a subset of L1's containing the injected keys, its `MODALIAS`
    equals the one derived from that bitmap;
  - (b2) every `udevprobe` line for event0, card0 and the `drm` enumeration equals the L1
    libudev-zero twin (`evidence/l1-zero`); `ID_INPUT`, `ID_INPUT_KEY`, `ID_INPUT_KEYBOARD` = 1
    as systemd-udevd wrote them on L1; the `input` enumeration lists event0; exit status 0;
  - (b3) libinput prints exactly one `DEVICE_ADDED` for event0 with `seat0 default group1 cap:k`,
    and its 18 `KEYBOARD_KEY` lines (name, code, pressed/released, in order) equal the sequence
    derived from the host keys and both L1 runs (udevd + systemd libudev; libudev-zero);
  - (b4) every refusal-log row is in `experiments/m7b-libinput/refused-by-design.txt` (the M7a
    rows, unchanged);
  - (b5) no `Unikraft Crash`; (x) the disk is byte-identical across the boot; `e2fsck -fn` clean.
- **Regression.** M3, M4 (a)–(d), M5a, M6, M7a, M8a and M8b each pass 3/3 on the M7b kernel.
- **L1 twin (oracle, not a pass).** Debian `linux-image-6.12.113+deb13-amd64` + `evdev.ko` +
  bochs-drm modules, initramfs with busybox, systemd-udevd/udevadm 257 (Debian `udev`,
  `libsystemd-shared`), the same libinput binaries under strace, the same `drive.py`
  (`run-l1.sh`, `LIBUDEV=debian|zero`). Reference runs 2026-10-19 15:03 (debian) and 15:02 (zero) CEST, both before this freeze.
  Accepted differences: device name `AT Translated Set 2 keyboard` (koru-os: `koru-os i8042
  keyboard (set 1)`); `atkbd` declares 145 key codes, koru-os 106; uevent `DRIVER=` values are
  koru-os's own driver names; L1 also enumerates `/dev/input/mice` (no mouse here); no
  `/sys/devices/virtual/dmi` on koru-os (libinput's DMI quirks match nothing, as on L1 with QEMU).
- **Not in M7b.** udev monitor / hotplug (netlink), seats and `ID_SEAT`, the udev database and
  rules, systemd's libudev (B16), DMI, sysfs attributes nobody read, write access to `/sys`.

**M9 acceptance: Hyprland + foot (DoD-3) — frozen 2026-10-19, 15:25 CEST, before any
acceptance run; first probes recorded the same afternoon.** The table criterion is unchanged:
a screendump shows a foot window; QMP keys type `echo DOD3 > /tmp/dod3`; `hyprctl -j clients`
lists class `foot`; after shutdown the host reads `/tmp/dod3` from the image. Native providers
stay in place (Q28 with Fabian); nothing here builds a silo path or prejudges the answer.
*Addendum 15:55 CEST:* Q28 is closed ("native first, silo variant as its own milestone
 afterwards"); M9 counts with the native providers.
- **Userland.** Debian forky (testing) packages, not trixie: Hyprland 0.56.2, aquamarine 0.15.1,
  foot 1.28.0, seatd/libseat 0.9.3, Mesa 26.1.6, libinput 1.30, fonts-dejavu-core, xkeyboard-config,
  fontconfig. Resolved and extracted under `/workspace/m9in` (`experiments/m9-hyprland/fetch.sh`,
  `mkroot.sh`); the image carries forky's glibc 2.43 and ld.so (the trixie box cannot run them).
  `libudev.so.1` is libudev-zero, as in M7b. polkitd, dbus, systemd, python and binutils from the
  Depends are *not* installed (Hyprland starts without them; polkit is for portals, not for KMS).
- **Seat.** libseat without logind. Probe result: the `builtin` backend forks an embedded
  seatd (`libseat/backend/seatd.c:686 Could not fork: Operation not supported`); koru-os has one
  address space (no `fork()` without `CLONE_VM`), so `builtin` is out. Next candidates, in this
  order: `LIBSEAT_BACKEND=noop` (opens the device nodes directly, no daemon, no VT; present in
  forky's `libseat.so.1`), then `LIBSEAT_BACKEND=seatd` with a seatd started by the init
  script (`SEATD_VTBOUND=0`; exercises `SCM_RIGHTS`). `XDG_RUNTIME_DIR` must be set (mode 0700);
  Hyprland aborts otherwise. Run as root with `--i-am-really-stupid` (the image has no other user).
- **Arm.** The M7b kernel (sysfs view, libinput path, DRM personality with page flips) plus
  whatever M9 adds; QEMU i440fx, `-vga none -device bochs-display`, TCG only, 2 GiB RAM.
  Host: QMP keys and screendumps (`experiments/m9-hyprland/`). Hyprland runs with
  `experiments/m9-hyprland/hyprland.lua` (stdout logs on, no animations/blur/shadows, no logo).
- **First probes (TCG, 15:12–15:25 CEST, not a pass; `run-probe.sh`):**
  - foot `--version`, Hyprland `--version`, `fc-match monospace` → `DejaVu Sans Mono`, seatd `-h`:
    all exit 0 under forky's glibc 2.43.
  - Hyprland with `LIBSEAT_BACKEND=builtin`: config manager, event loop, PointerManager come up;
    aquamarine then fails `libseat: failed to open a seat` (fork, above) → DRM backend failed →
    wayland fallback has no parent compositor → `CBackend::create() failed!`, abort.
  - Refusal rows seen so far: `signalfd4`, `inotify_init1` (Hyprland only loses config reload),
    `clone3` (glibc falls back to `clone`), non-`CLONE_VM` clones (crash reporter, `fork()` for
    child processes — so foot must be started by the init script, not by Hyprland's `exec`),
    `sched_get_priority_min`/`sched_getparam`/`sched_getscheduler`, STUBBED `alarm`,
    `sched_getaffinity`.
  - Shell side notes: an `execve()` of a missing file under `PATH` returns `EINVAL` (app-elfloader)
    instead of `ENOENT`, so hush stops searching (probes use `PATH=/bin:/usr/bin:/usr/sbin`); a
    process still running when init exits can crash the kernel in `sys_error_handler` (probes
    stop Hyprland before the end).
- **Probes 3–4 (15:26–15:31 CEST, not a pass):** `LIBSEAT_BACKEND=noop` opens the seat
  without fork. aquamarine then needs a udev monitor; libudev-zero opens it on `AF_NETLINK`,
  which Unikraft 0.21 does not offer here, so koru-os carries a 30-line libudev-zero patch
  (`experiments/m9-hyprland/patches/libudev-zero-pipe-monitor.patch`): without netlink the
  monitor fd is a pipe that never fires (koru-os has no hotplug; the device set is published
  once at boot). With it, libinput's **udev** backend finds event0 ("tagged by udev as:
  Keyboard"), aquamarine enumerates `/sys/devices/pci0000:00/0000:00:03.0/drm/card0`, accepts
  it as KMS-capable ("driver korukms"), registers the GPU, and stops at
  `drm: DRM_PRIME_CAP_IMPORT unsupported` (B18). A thread assertion at kernel shutdown after
  Hyprland's abort (`thread.c:151`) is noted with the init-exit crash above.
- **Expected next gaps (to confirm by probe, not assumed):** whether aquamarine's DRM backend
  accepts the legacy-only personality or needs atomic KMS (`AQ_NO_ATOMIC=1` exists); GBM/EGL
  dmabuf import with kms_swrast; `memfd_create` + seals and `SCM_RIGHTS` for foot's `wl_shm`;
  `signalfd4` if a client needs it.
- **Probes 5–7 (15:41–15:47 CEST, not a pass):** PRIME (B18) in the DRM personality lets
  aquamarine pass its feature check; then it needed `DRM_CAP_CRTC_IN_VBLANK_EVENT`, a plane
  `type` property and a connector `DPMS` property (legacy KMS: `DRM_CLIENT_CAP_ATOMIC` is refused,
  aquamarine falls back to its legacy implementation on its own), and `GET_MAGIC`/`AUTH_MAGIC` on
  a second open of card0 (its GBM allocator reopens the node). With those, Hyprland modesets
  1280x800 and page-flips continuously; the probe-7 screendump is Hyprland's own frame (solid
  `#111111` background and the software cursor in the centre; sha256 in the evidence). Still
  logged every frame and not yet understood: aquamarine's multi-GPU blit renderer fails
  (`eglQueryDeviceStringEXT` → `EGL_BAD_PARAMETER`, "no matching devices"); frames reach KMS
  regardless.
- **`/tmp/dod3` policy (h3) — decided 2026-10-19 15:50 CEST, before any counted run.** Of the
  three options left open above, M9 takes the **snapshotted ramfs `/tmp`**. `/tmp` stays the
  ramfs; the root image stays read-only and untouched. The guest snapshots explicitly: after
  the QMP keys and before shutdown, the init script runs `tar -cf /dev/korusnap /tmp/dod3`
  (busybox tar). `/dev/korusnap` (`lib/korusnap`) accepts one byte stream per boot and on close
  writes it to block device 1, a second, empty 8 MiB scratch virtio-blk image, as a 512-byte
  header `KORUSNAP1 <length>` plus the stream. After QEMU exits, the host (`run-probe.sh`)
  decodes that image to `snap.bin` and reads `tmp/dod3` from the tar. (h3) passes only if that
  member exists and is exactly `DOD3\n`. A writable koruext2 lift was not taken (it would be the
  first write path into the root filesystem, out of proportion for one file). Smoke test
  15:49 CEST (`experiments/m9-hyprland/evidence/korusnap-smoke`): 2048 bytes persisted, the host
  extracts `tmp/dod3` = `DOD3\n`.
- **Probe 8 (17:15 CEST, not a pass): foot runs as a Hyprland window.** foot cannot fork its
  shell here, so it runs as `foot --pty=/dev/korupty0` on a pty pair from `lib/korupty`, with
  busybox `sh -i` on the slave, both started by the init script. The way there needed, in the kernel
  (`experiments/m9-hyprland/patches`): `SO_PEERCRED` (libwayland-server refuses a client without
  it); clearing a listener's POLLIN once its accept queue drains (a stale level event made
  Hyprland block in `accept4` and freeze); `SCM_RIGHTS` queued per pipe node rather than per
  pipe end; zeroing the `cmsghdr` before filling it (musl's 4-byte `cmsg_len` plus padding,
  read by glibc as a `size_t`: libwayland-client grew a 128 GiB ring buffer); `epoll_pwait`
  and `ppoll` with a signal mask (the mask is swapped around the wait, not atomically); POSIX
  shm (`/dev/shm/NAME` is served by `lib/korumemfd`; Hyprland's keymap uses an rw/ro shm pair
  and `fchmod`, so devfs `setattr` is accepted and ignored); devfs `fallocate` refused (with a
  fake success, foot's punch-hole probe passes and it maps a 128 GiB pool); a device mmap
  refusal returned as an error instead of a copy-on-fault file mapping; `FIONBIO` on the pty.
  hyprctl then needed pathname unix names compared up to the first NUL (it passes
  `sizeof(struct sockaddr_un)`) and `SO_RCVTIMEO` accepted. Screendump sha256 in
  `evidence/probe-8-foot-window`.
- **Check decisions (2026-10-19 17:42 CEST (commit 5f94950), before the first counted run; `check.py`).**
  (h1) koru-os unix sockets have no filesystem node, so "a socket under `$XDG_RUNTIME_DIR/hypr/`"
  is evidenced by Hyprland's "Hypr socket started at …/hypr/<signature>/.socket.sock" log line
  and hyprctl connecting to that path; the monitors JSON must list `Virtual-1` (the korukms
  bochs connector) at 1280x800. (h2) is split into two required parts: (h2a) the frozen trigger,
  in Hyprland 0.56's Lua form `hyprctl dispatch "hl.dsp.exec_cmd('foot')"`, returns `ok`;
  (h2b) the bounding-box variant (the L1 twin has no reference yet): pixels of foot's default
  background `#242424` cover >= 50 % of the 1280x800 screendump in a box that is >= 90 % filled.
  The foot window measured in (h2b)-(h4) is the init-started `foot --pty`, which the frozen text
  does not name. **Known before measuring:** (h2a) fails on koru-os. Hyprland's executor forks
  (`clone` without `CLONE_VM`: "Multiple address spaces are not supported", Hyprland logs
  "Fail to fork"). That is the Q19 process-model question, not a gap of M9's own. The keys are
  sent as one QMP `input-send-event` per character, with press and release together: in
  rehearsal 3, separate releases arrived after the client's key-repeat delay ("eeeeecho").
  Refusal rows: `experiments/m9-hyprland/refused-by-design.txt`. Runner: `run-m9.sh` +
  `drive-m9.py` + `m9-accept-init`.
- **Counted runs (2026-10-19 17:43–17:47 CEST, TCG, kernel sha256 `595f8c05…`, built from
  `5f94950`): M9 not passed as frozen.** 3/3 runs give the same result: (h1) PASS (IPC socket,
  `Virtual-1` 1280x800); **(h2a) FAIL** (exec dispatch: `CLONE_VM not set`, "Failed to start
  process", B20); (h2b) PASS (foot box 1238x758, cover 0.92, fill 1.00); (h3) PASS (the host
  extracts `tmp/dod3` = `DOD3\n` from the korusnap stream after shutdown, typed by QMP into foot);
  (h4) PASS (`"class": "foot"`); (h5) PASS (17 row names, all in `refused-by-design.txt`); (x) PASS
  (no crash; root read-only; snapshot written). Wall time 57–59 s per run. Evidence:
  `experiments/m9-hyprland/evidence/accept-run-{1,2,3}` (screendumps as sha256 only).
  Regressions on the same kernel (17:46–17:53): M7b 3/3, then M3, M4 (a)–(d), M5a, M6, M7, M8a
  and M8b each 3/3 (`evidence/regress-m9-accept`). No L1 twin run yet (an oracle, never a pass).
- **Q29 (ruled 2026-10-19 about 18:20 CEST: M9 stays open, (h2) not amended, Spawn design first, §8.6 and §12 Q29–Q30):** (h2) as frozen requires Hyprland to start foot (`hyprctl dispatch
  exec foot`), and that needs fork. Choices: (a) amend (h2) so that the screendump shows the foot
  window started by init as `foot --pty` (then the counted runs above pass all other checks
  3/3); (b) keep (h2) and make spawning work, either a process model with fork (Q19) or a
  fork-free spawn in Hyprland's executor (a patch to Hyprland); (c) another trigger he names.
  Until he rules, M9 is reported as failing (h2a).
- **Gated checks** (to be filled into `experiments/m9-hyprland/check.py` before the first
  acceptance run; the freeze does not invent numbers):
  - (h1) Hyprland reaches a running compositor (a socket under `$XDG_RUNTIME_DIR/hypr/` and a
    non-empty `hyprctl -j monitors` listing the bochs connector);
  - (h2) a screendump after `hyprctl dispatch exec foot` shows the foot window (pixel hash, or
    a visible bounding box against a solid wallpaper, decided when the L1 twin has a reference);
  - (h3) QMP keys of `echo DOD3 > /tmp/dod3` + Enter, typed into that foot, produce a file
    `/tmp/dod3` with contents `DOD3\n` that the host recovers after shutdown (koruext2 is
    currently read-only — either a ramfs `/tmp` that is snapshotted, a writable lift of
    koruext2, or writing onto an already-writable mount; decided before measuring);
  - (h4) `hyprctl -j clients` lists a client with `"class": "foot"`;
  - (h5) every refusal-log row is in `refused-by-design.txt`; (x) no Unikraft Crash; disk policy
    for (h3) is met.
- **Regression.** M3–M8b each pass 3/3 on the M9 kernel.
- **L1 twin (oracle).** The same Hyprland/foot binaries on Debian linux-image-6.12 + bochs-drm +
  i8042/atkbd, with libudev-zero and `LIBSEAT_BACKEND=builtin`, same QMP and screendumps. Never
  a pass.
- **Not in M9.** portals / polkit / dbus user session, Xwayland, a multi-seat setup, DS3/DS4
  (Q28), cursor themes beyond the default, a network, sound, a mouse (keyboard only, as M7).

### 0.5 Biggest risks

1. **GPU and input drivers in a silo.** LKL's supported hosts are POSIX and Windows
   userspace (C, lkl/linux README). A Unikraft host port, PCI/MMIO and interrupt access
   from the silo, and DMA mapping are all D. KolibriOS GPU drivers (`i915`, `radeon`,
   `vmwgfx` on an older Linux DRM snapshot via `drivers/ddk/linux`) target the
   KolibriOS kernel service API, not the Linux uAPI. Their snapshot age is not
   determined.
2. **`fork` and process model on Unikraft** (Q19). This decides whether real shells run
   unmodified.
3. **Software rendering.** KVM is available, but llvmpipe in the guest may still be
   too slow for Hyprland to start within test timeouts (unmeasured).
4. **Surface size.** The AUR `hyprland-git` page lists 59 dependencies, including
   build-time and optional ones (C), and Qt 6 adds more. Each one widens the row set
   and the TCB (§8, R-RUNG-1).
5. **Licence boundary.** LKL is GPL-2.0-only (C, SUSE package metadata) and KolibriOS
   is GPL-2.0 (V, `COPYING.TXT`). Whether a silo boundary keeps them separate from the
   koru-os image for licence purposes is a legal question, not an engineering one
   (Q26). The koru licence itself is unsettled (README says MIT, no LICENSE file, V).
6. **Upstream churn.** The hypr libraries break ABI between releases, and quickshell
   says it still takes breaking changes (C). Pin versions per milestone.


### 0.6 Driver silos: Linux and KolibriOS as driver personalities, not as the OS (D)

**Ruling (Fabian, DRAFT 5).** Linux enters koru-os only as a **slim, container-like
shim used exclusively for driver packages**. LKL is accepted inside that model.
KolibriOS drivers are a second driver source, with the GPL-2.0 caveat. Everything
below is design (D) unless marked.

**Definition.** A *driver silo* is a silo (§8) with three properties:
- its only exports are correspondence rows from a closed **driver row set**: `blk.*`,
  `net.*`, `kms.*` (a DRM/KMS subset) and `input.*` (an evdev subset);
- its only imports are host-service rows: memory, threads, timers, an IRQ, a DMA window,
  and one device grant;
- every other identity is refused loudly at the silo boundary.

The driver code inside (LKL or KolibriOS-derived) is the silo's *personality*.
Applications never see it, and it never sees application syscalls.

```
 app (Hyprland, foot, ash)                        unmodified Linux ELF
   │  linux.sys.* / linux.ioctl.*                 L2 syscall_shim or L3 table
   ▼
 Linux-ABI personality ── refuses unlisted rows ──► refusal log
   │  kms.* / input.* / blk.* / net.*              driver rows (Appendix C.4)
   ▼
 membrane (rung 1 minted handles; rung 2 page-table domain when available)
   ▼
 driver silo  [personality: lkl@<sha> | kolibri@<sha>:<driver>]
   │  host.* rows: mem, thread, timer, irq, dma, device-grant
   ▼
 koru-os core (Unikraft arm)  ──►  QEMU device (virtio-gpu, vmware-svga, virtio-blk, …)
```

**Driver package manifest** (the "image" in the container analogy; pinned in the
manner of `vand`'s `origins.lock`, §0.2):

| field | example | rule |
|---|---|---|
| `silo` | `gpu0` | identity of the silo instance |
| `personality` | `lkl@<sha>` or `kolibri@69df0061:vmwgfx` | pinned source; no floating refs |
| `licence` | `GPL-2.0-only` | recorded; the image builder refuses a mix the licence policy does not allow (Q26) |
| `device` | PCI BDF or virtio-mmio region, IRQ line, DMA window size | exactly one device per silo at first |
| `exports` | `kms.{getresources,getconnector,create_dumb,map_dumb,addfb2,atomic,page_flip,event}` | closed list; anything else is refused |
| `imports` | `host.{mem.alloc,thread.spawn,timer.arm,irq.wait,dma.map}` | the silo cannot reach anything else |
| `firmware` | blob hashes, if any | the only files the silo may read |
| `evidence` | V/M/C/D per exported row | R-SILO-1 | Every non-koru driver (LKL, KolibriOS-derived) runs in a driver silo, never in the core image | image builder lists core objects; any GPL-2.0 object in the core fails the build | §0.6 |
| R-SILO-2 | A driver silo exports only rows from the driver row set (`blk.*`, `net.*`, `kms.*`, `input.*`) declared in its manifest; every other identity is refused with a log entry naming identity and silo | DS0 harness: an empty-manifest silo refuses all calls; a fuzzed ioctl outside the manifest is refused | §0.6, Appendix C.4 |
| R-SILO-3 | A driver silo imports only `host.*` rows and exactly the device granted in its manifest | DS0: access to an ungranted BAR/IRQ/DMA range is refused | §0.6 |
| R-SILO-4 | Silo restart bumps its epoch; handles from the old epoch are refused with `revoked`, not hung | kill-and-restart test during M6 | §0.6, §8.5 |
| R-SILO-5 | Each driver package is pinned (personality SHA, driver name, licence, firmware hashes) | manifest lint rejects floating refs | §0.6 |
| R-UI-1 | QML (quickshell) is the canonical DoD-4 exemplar; HTML/component tracks are tracked separately and do not gate DoD | M10 uses a QML surface | §0.3 |
| R-EVID-1 |

**Slim means:**
- the silo has no init, no shell, no userspace and no filesystem of its own (only the
  listed firmware);
- it has no network unless it is the `net` silo;
- it does not dispatch syscalls for anyone but its own personality runtime.

**Lifecycle and revocation.** Each silo has an epoch (§8.5). A crash, watchdog expiry or
operator restart bumps the epoch, so every handle minted against the old epoch is
refused. Clients see a loud `revoked` refusal, never a hang. Device state is reset by
re-granting the device. Rollback inside the silo is out of scope.

**Two personalities:**

| | LKL (`lkl/linux`) | KolibriOS-derived (`KolibriOS/kolibrios` @ `69df0061`) |
|---|---|---|
| status | active: commits to Mar 2026; SUSE ships x86-64 packages, latest 2026-09-16; labelled experimental (C) | active monorepo (V) |
| licence | GPL-2.0-only (C) | GPL-2.0 (V, `COPYING.TXT`) |
| how it is hosted | kernel built as a library (`arch/lkl`), driven through host operations; hosts today are POSIX and Windows userspace (C). **A Unikraft host port is D** (Q25) | drivers are `.sys` modules importing KolibriOS kernel services; needs a **KolibriOS driver-service personality** on koru-os (D). The import list is not yet enumerated |
| upper API | the Linux syscall API (`lkl_sys_*`), so `kms.*` and `input.*` rows can forward a whitelisted ioctl almost one to one (?) | the KolibriOS service API, so the translation to `kms.*`/`input.*` must be written (D) |
| drivers relevant to QEMU | Linux has `virtio_blk`, `virtio_net`, `virtio_gpu` and `virtio_input` (C; whether they work under LKL with real PCI access is unknown, Q25) | `drivers/ethernet`: `RTL8139`, `pcnet32`, `i8254x` (e1000) and others; `drivers/usb`: `xhci`, `usbhid`, `usbstor`; `drivers/mouse`: `ps2mouse4d`; `drivers/disk`: `virt_disk`, `tmpdisk`; kernel `blkdev/ahci.inc`; `drivers/video/drm`: an older Linux DRM core plus `i915`, `radeon`, `vmwgfx`, `ttm`, through a `drivers/ddk/linux` compatibility layer; Mesa 10.6.0 in `contrib/sdk` (all V, tree listing only). **No virtio driver exists in the tree (V).** QEMU 10 on the box offers `rtl8139`, `pcnet`, `e1000`, `ich9-ahci`, `qemu-xhci`, `usb-kbd` and `vmware-svga` (V) |
| language | C | fasm assembly; C for the DRM ports |
| FS | ext4 and others in-tree, so DS1 serves DoD-1 | kernel `fs/`: FAT, ext, exFAT, NTFS, XFS, ISO 9660 (V, file names). These are kernel `.inc`, not silo-ready drivers |

**fasm and fasmg.**
- fasm 1.73 is in-tree at `programs/develop/fasm` (V). No path in the tree mentions
  `fasmg` (V).
- The "community fasmg packages" Fabian mentions are therefore elsewhere, location
  unknown (Q24).
- fasmg is a macro assembler whose instruction sets ship as macro packages (C, general
  knowledge). That makes it a plausible way to assemble KolibriOS drivers for a
  different target. This is not checked.

**Position.** LKL is the primary personality for `blk` (DS1), `kms` (DS3) and `input`
(DS4), because its upper API already *is* the Linux uAPI that the rows name. KolibriOS
is the second source and the cheaper first proof of the silo mechanism (DS2: a small,
self-contained `.sys` driver). It also gives a second GPU route through `vmwgfx` on
`vmware-svga`. Neither personality's code enters the koru-os core image.

---

## 1. Purpose and non-goals

### Purpose

koru-os is a **platform namespace beside `std`** in korulang/koru. It gives a Koru
program one contract for running on several substrates. Each substrate is an
**optional platform arm** that realizes the same interfaces differently, for example a Unikraft
unikernel, a hosted Linux process, or a bare i686 image.

The contract has one rule, applied the same way on every platform arm:

> Every interface a program requires is resolved to a provider through a persistent,
> evidenced correspondence row, and then realized as an ephemeral live binding.
> A requirement with no row, or a row with no realizable provider, is refused loudly,
> at the earliest phase that can know it.

### Non-goals

- **Not a new kernel first.** Platform arms reuse existing substrates (Unikraft, a host OS,
  plex-os) before anything is written from scratch.
- **Not separate OS instantiations.** One namespace, many platform arms, and each platform arm is optional.
- **Not syscall emulation.** Binary compatibility routes, such as Unikraft's ELF
  loader, are a separate platform arm with their own rows. They are never a fallback.
- **Not a single unrestricted heap.** "Single address space" means one coherent
  namespace (§6), not the absence of protection.
- **Not a reuse of plex-shell's decorative parts.** That covers SASOS, multikernel,
  PCC, the "quine" cipher and secure_channel (see `notes/plex-shell-crates.md` §3.8).

---

## 2. Terminology: pointer to the ccomp concordance matrix

The canonical Koru-term to CS-term mapping is Fabian's **Concordance Matrix**:

- **File:** `docs/concordance-matrix.md`
- **Repo:** `Cypoe/koru`
- **Branch:** `ccomp`
- **Commit:** `601ba53db4ff993c2f8584847b655bed6cfe70ee` (V, read 2026-10-18)

It holds 60 rows in three tables: grammar core, obligation vocabulary, and verification
vocabulary. It also has a drift-risk list and a proposed registration gate.

Its companions are `docs/refusal-matrix.md` and `docs/obligation-matrix.md`, which also
exist on upstream `korulang/koru@3d81f837`.

This note uses the matrix's mappings and does not restate them. Terms used below, as
the matrix maps them:

- `phantom` `<state>` ~ phantom type parameter / typestate.
- `obligation` ~ relevant (strict) linear use, with no implicit drop.
- `mint` ~ obligation creation (ledger open edge).
- `discharge` ~ explicit dispose (ledger close edge).
- polarity `borrow`/`consume`/`issue`; `issue` means the obligation leaves through a
  declared output.
- `custody` ~ ownership as an interval.
- `tor` ~ outcome-typed function.
- `branch` ~ named result.
- `arm` ~ match arm.
- `flow` ~ elaborated CFG region.
- `transform` ~ rewrite pass.

### 2.1 Conflicts with DRAFT 1 of this note (the matrix wins)

DRAFT 1 had its own concordance table. These of its mappings contradicted the matrix
and are withdrawn:

| DRAFT 1 said | matrix says | consequence here |
|---|---|---|
| consume/discharge ~ "linear (or affine, with an escape)" | strict/relevant linear; affine is explicitly ruled out because it permits implicit drop | "affine" removed; an escape is `issue`/`issued`, not affine drop |
| issue and mint as one term (`T<s!>` = "typestate introduction; capability minting") | `mint` = obligation creation; `issue` = a polarity where the obligation leaves through a declared output (`issued` ~ ownership transfer to caller) | treated as two terms |
| tor ~ "effect operation; event continuation" | tor ~ function/procedure, outcome-typed (warranted neologism (p)) | the effect/continuation reading is dropped |
| branch ~ "sum-type case and continuation" | branch ~ named result / tagged return value; `arm` is the case alternative | branch and arm are separated |
| flow ~ "continuation graph or pipeline" | flow ~ CFG region, the elaborated (post-transform, pre-emission) graph | adopted |
| custody transit ~ "ownership transfer" | custody ~ ownership, read as an interval; whether `custody` is a mere alias for `ownership` is an open drift risk (Lars rules) | "ownership transfer" kept only as a gloss, not a ruling |

Collision: the matrix's `arm` means a match arm (`| x` outcome arm, `! x` interceptor
arm). This note's "arm" means a substrate realization (Unikraft, hosted, plex-os).

To avoid a second meaning of the same surface word, **this note writes "platform arm"
for the substrate sense throughout.** The term is proposed for registration below.

### 2.2 Additions proposed upstream to the ccomp matrix

These are koru-os or ecosystem terms that the matrix lacks. Each is a proposed row
(term · nearest canon · delta). The ruling is `unplaced`, because Lars rules.

Per the matrix's own §4 precedent, a row is a claim about the tree. The terms marked
"not yet in tree" must wait until code exists.

| term | nearest canon | delta | in tree? |
|---|---|---|---|
| `refusal` (`ast.refusal`, KORU1xx) | static rejection / fail-closed diagnostic | always loud, never a silent rewrite; sites are projected by `refusal-matrix.md` but the noun has no concordance row | yes (`ast.refusal` in `foreign.kz`, `store.refs.kz`) |
| `supervised` (`std/supervisor`) | restart strategy (Erlang/OTP) | elaborated at compile time into a bounded `#`/`@` retry fold; there is no runtime supervisor object | yes (`koru_std/supervisor.kz`) |
| `foreign` (`std/foreign:struct`) | opaque / extern type declaration (FFI) | registers names and bare fields only; the host owns layout; inspection-only (ruled 2026-09-04) | yes (`koru_std/foreign.kz`) |
| `ref(T)` | typed foreign key / row handle | i64 row handle with a validated target type (KORU161) | yes (`koru_std/store.refs.kz`) |
| `home` / `refhome` | owning module / namespace of a declaration | one authority answers "who are the homes of `ref(T)`" | yes (`store.refhome*.kz`, `channel.home.kz`) |
| `scope` (`std/runtime`) | capability allowlist plus dispatcher | generated at compile time from declarations | yes (`koru_std/runtime*.kz`) |
| `bridge` / `session` (`std/bridge`) | durable REPL / session environment with a capability scope | the session is itself an obligation (`<session!>`, discharged only by `close`) | yes (`koru_std/bridge*.kz`) |
| `platform namespace` | target / platform layer (HAL) | path alias beside `std` (`unikraft`); a miss is a loud "module not found" | yes (`src/config.zig` comment) |
| `platform arm` | target backend / port | one substrate's realization of the same interfaces; avoids the `arm` collision | not yet in tree (koru-os) |
| `correspondence row` | symbol-resolution record plus provenance (linker / NID table) | persistent: foreign name ↔ minted interface ↔ provider, with lineage and evidence | **in tree** (koru-os `koru/nid/index.kz` `Row`, 2026-10-19) |
| `live binding` | resolved PLT/GOT entry / capability handle | ephemeral: carries instance, generation and an obligation lifetime | **in tree** (`koruos/nid` `*Binding<live!>`, minted by `resolve`, discharged by `release`) |
| `generation` | epoch / incarnation number | a stale generation is refused at use, never redirected | **in tree** (`koruos/nid` `call` → `\| stale`, bumped by `retarget`) |
| `NID` | symbol hash / name id (PS4/PS5 NID, ELF `DT_GNU_HASH` key) | koru-os: 64-bit sha256 prefix of `scheme/ns/version/name` under a versioned domain; a comparison key, never authority; collisions refused | in tree (`koruos/nid`) |
| `retarget` | relink / symbol interposition (AnyPS5 re-link) | re-points an interface's rows to another provider export; NIDs and call sites unchanged; bumps the generation | in tree (`koruos/nid:retarget`) |
| `occlude` (row) | supersede / shadow (version shadowing) | the `evolve` verb's effect on the parent row: it stays, listed, unresolvable | in tree (`koruos/nid` `occluded_by`; matches koru-distill `Occludes:`) |
| `evidence class` (V/M/C/D) | provenance level / assurance level | verified-now, measured, carried-over, design-only | not yet in tree (koru-os) |

### 2.3 The concordance as the third matrix, and the verification-path gate

*Recorded 2026-10-19 about 18:40 CEST from Fabian's whitepaper analysis (ch.06/08 of `Cypoe/plex-shell` @ `f34e473f`, now readable through GitHub). Decisions are Fabian's, or a synthesis he endorsed by pasting it; the wording here is this note's.*

There is **no second matrix**. The ccomp concordance matrix (`Cypoe/koru`, branch `ccomp`,
`docs/concordance-matrix.md`) is the seed, and it wins:

- the file was last changed at `a1218e1f` (2026-10-17);
- the ccomp tip at re-read was `b39a442f` (2026-10-18);
- V, read through GitHub 2026-10-19.

It is the **third matrix** beside the refusal and obligation matrices. Its row shape is already
the gate's shape: `term | first minted | nearest canon | delta | ruling`. Its ruling values are
`canon-alias`, `warranted neologism` and `unplaced`. The paste's "justified neologism" and
"unclassified" are the same two values under the matrix's names; the matrix's names are used.

**Gate (the matrix's own proposed gate, endorsed by Fabian for koru-os).** Every new surface
noun or verb in a PR must cite an existing row or add one:

- the **ruling may pend** (`unplaced`, Lars rules);
- the **registration may not**.

For koru-os this applies to every term in this note and in koru-os code. The proposed rows of
§2.2 are the koru-os backlog against it. New terms since DRAFT 5 that still need registering
include: `spawn`, `grant`, `rights bag`, `seal`, `detach`, `replace` (§8.6), `realization graph`
(§11.0) and `interface descriptor` (§3.6).

**History and provenance outrank the final artifact.** A row records when and where a term was
first minted and how it evolved. That is the same lineage discipline as §3.2.

---

## 3. The execution contract

### 3.0 Layering

*Folded in 2026-10-19 about 18:30 CEST from design material Fabian supplied (authoritative guidance; the wording here is this note's).*

```
Koru program / semantic object
        │
        ▼
Koru execution contract        imports, effects, resources, lifecycle, session
        │
        ▼
Substrate projection           Linux-hosted  |  native kernel  |  other host
```

The contract is the middle layer and the only one a program depends on. A substrate is a
projection of the contract, never a substitute for it: the platform arms (§4) and the Linux-ABI
routes L1–L3 (§0.1) are projections. Each **required interface** resolves to four things:

1. an interface identifier;
2. a contract and its version;
3. an **authorized** provider (authorization is part of resolution, not something checked
   afterwards);
4. a target-specific entry point or adapter.

The **binding chain** runs from the program's import, through a persistent correspondence row
(§3.2), to an ephemeral live binding (§3.3), and ends at a materialized entry or storage location
(§3.8). Only the last link is an address.


### 3.1 Identity is not location

A pointer is a memoized resolution, not an identity. The precedent is PS4/PS5
dynamic linking (C):

- Imports are named by a NID, a short hash of the symbol name. The commonly described
  scheme is a truncated, salted SHA-1, rendered as 11 base64 characters. The exact
  derivation is a carried-over claim and needs checking against shadPS4.
- The loader resolves the NID per module and library.
- Re-linkers (AnyPS5) and emulators (shadPS4) re-target the same NIDs to new providers
  without touching call sites.

What koru-os takes from this precedent is the separation itself, not the hash. Three
identities are kept apart:

1. **Interface identity.** What is promised: the operation names, branch vocabulary,
   obligation signature and costs.
2. **Artifact identity.** What was built: a content hash of the object or image that
   provides the interface.
3. **Evidence identity.** What supports a claim that (2) realizes (1): a test,
   measurement, proof or review, with provenance.

A NID-style hash is the **mechanism** that makes identity cheap to compare at link or
load time. It is **not the contract**. The contract is the minted interface plus its
lineage.

The three identities map onto three kinds of record, and none of them stands in for another:

| identity | question | record |
|---|---|---|
| interface | which operation and contract | the **NID discipline**: the minted name and contract revision of a row (§3.2) |
| artifact | which exact implementation bytes | build and content hashes (image, object, library) |
| evidence | what supports the claim of satisfaction | verification receipts: test runs, measurements, proofs, reviews, each with provenance (§3.2 `evidence`) |

A NID is the **naming mechanism** for mint-plus-lineage, not the whole discipline: the discipline
is minting, evolve-don't-mutate (§3.2) and lineage. Interface identity is never equated with
implementation identity. Two artifacts can realize one interface, and one artifact can, through
separate rows, realize two interfaces.


### 3.2 Correspondence rows (persistent)

A row has these fields:

```
row {
  foreign:   { scheme, namespace|library, version, nid }        -- how a caller names it
  interface: { minted_name, contract_revision }                 -- what is promised
  provider:  { platform_arm, export_symbol|endpoint|mechanism, artifact } -- who realizes it
  lineage:   { parents[], verb: create|evolve|split|merge|correct }
  evidence:  [ { class: V|M|C|D, ref, observed_at } ]
}
```

**Resolution scope.** The three sides of a row are three scopes:

- a **foreign import** is named by scheme + namespace or library + version + NID (how a caller
  outside Koru names it);
- the **canonical** name is the minted interface id + contract revision;
- the **correspondence** links the two, and links both to a provider export.

Rules:

- **Evolve, don't mutate.** An incompatible change to an interface yields a new
  interface identity and a new row. The old row stays, marked occluded by the new one.
  This is the same lineage discipline as the Koru membrane (`koru-distill/DISCIPLINE.md`
  §1: create, evolve, merge, split, correct, move).
- **Rows live in `std/store`, not in `std/foreign`.** `std/foreign` is ruled
  inspection-only forever (V, `koru_std/foreign.kz` header, ruling dated 2026-09-04): it
  mints a name and the host owns the substance. A correspondence row is substance, so
  it belongs in a store, typed with `ref(T)` handles (`store.refs.kz`,
  `store.refhomeapi.kz`, V), with custody of bindings carried by `std/channel`
  (`channel.custody.kz`, `channel.transit.kz`, `channel.home.kz`, V).
- **Equality between foreign names is an asserted row, never inferred.** This is the
  KoruFlow rule (plex-shell `docs/concepts/koruflow-semantic-capability-protocol.md`
  §5): `imdb:… ~ tmdb:… ~ local:…` is a server-side assertion with provenance.

### 3.3 Live bindings (ephemeral)

```
binding { row, instance, generation, lifetime: obligation }
```

- A binding is minted from a row on one platform arm, in one instance, at one generation. It is
  discharged when the instance ends or the row is superseded.
- `generation` increments each time a provider is replaced, for example a restarted
  service. A stale binding refers to an older generation and must be refused, not
  silently redirected.
- On the Unikraft platform arm a binding is usually a direct call into the same address space.
  BUILD.md (C) reports nolibc calls with no syscall shim. On a microkernel platform arm it would
  be an RPC stub to a service endpoint. On the hosted platform arm it is a libc or syscall call.

### 3.4 Resolution phases and refusal

Resolution happens at the earliest phase that has the information:

| phase | refuses when | existing Koru mechanism |
|---|---|---|
| import | the platform namespace is absent | `src/config.zig`: `unikraft` resolves to two candidate layouts, and a miss is a loud "module not found", never a fallback (V) |
| compile | an obligation is undischarged, a branch is unhandled, or a ref target is unknown | phantom checker (`KORU030` use-after-discharge, V in `unikraft/store/README.md`); `store.refs.kz` refuses with `KORU161` (V) |
| configure | a required interface has no row for the selected platform arm | **M** for `koruos/nid` programs (§11.7): `realize gen` refuses a required import with no row, a wrong version, a refused table or a NID collision, before an image exists; Unikraft rows §11.1 |
| link | a symbol is unshimmed or unbound | **D** (plex-os `libc_shim` today returns `-1` at runtime; see `notes/plex-os-study.md`) |
| run | a binding is stale (generation), a lease has expired, or budget is exhausted | partial: plex-net `execute_flow` and `UCANLease` (read, plex-shell) |

Refusal has a fixed shape. It names the required interface, the platform arm, the phase and
the missing piece, and it offers no substitute. "No dishonest fallback" (KoruFlow
law 6) is the governing rule.

The failure mode this guards against has already happened. Unikraft's `addlib` with
a wrong prefix succeeds silently, links the weak `main`, boots, prints nothing, and
exits zero (V, `koru-libs/unikraft/index.kz` header).

### 3.5 Output of resolution

For every build, on every platform arm, resolution emits three tables:

1. `required interface -> selected provider -> realized binding`
2. `required resource -> mechanism -> cost` (bytes, pages, RAM floor, stack)
3. `missing obligation -> explicit refusal`

A build with a non-empty table 3 does not produce an image.

### 3.6 The interface descriptor and binding admission

*Folded in 2026-10-19 about 18:30 CEST from design material Fabian supplied (authoritative guidance; the wording here is this note's).*

A name and a version are not enough to bind. Beyond the row fields of §3.2, an interface
descriptor states:

| field | what it fixes |
|---|---|
| calling convention and target data layout | ABI, struct layout, endianness, alignment, pointer width per target |
| ownership, borrowing, lifetime | who owns each argument and result, what is borrowed and for how long, which obligations a call mints or discharges (phantom states) |
| permitted effects and required authority | what the provider may do (I/O, allocation, blocking, spawning), and which rung-1 authority (§8.4) the caller must hold |
| failure and cancellation | the branch vocabulary for failure, what a cancelled call leaves behind, and whether the call can be retried |
| reentrancy and concurrency | whether the provider may be re-entered or called concurrently, and from which contexts (thread, interrupt, cooperative yield) |
| contract version and available evidence | the revision this descriptor belongs to, and the evidence (§3.1) that a given provider artifact meets it |

**Binding is admission.** A binding (§3.3) is minted only if the caller's requirements and the
provider's descriptor match on every field. A mismatch is a refusal **before execution**, at the
earliest phase that knows it (§3.4), with the fixed refusal shape. Any change to a descriptor field
is a new contract revision (evolve, §3.2), never an edit in place.

**The ABI claim is narrow.** koru-os claims compatibility only at the named import and linker
boundary: the names, descriptors and conventions above. Addresses are materialized only inside
the selected realization (one image, one load, one service connection). No address, layout or
offset outside that realization is part of any promise.

### 3.7 Two obligations: validated compilation and correct providers

*Folded in 2026-10-19 about 18:30 CEST from design material Fabian supplied (authoritative guidance; the wording here is this note's).*

Following the CompCert distinction (C), two results are kept as separate obligations with
separate evidence:

1. **Compilation validation:** the generated code faithfully implements the Koru source
   (translation validation, a verified compiler, or tests of the compiler).
2. **Provider correctness:** the external provider behind an FFI row (a C library, a syscall,
   a Unikraft lift, a driver silo) actually behaves as its interface descriptor says.

"The generated code was validated" never silently becomes "the external service behaves
correctly". A provider row carries its own evidence, or it is listed in the TCB manifest (§8.4,
FFI rule). A validated caller of an unevidenced provider is reported as exactly that.

### 3.8 Memoized resolution and its invalidation

*Folded in 2026-10-19 about 18:30 CEST from design material Fabian supplied (authoritative guidance; the wording here is this note's).*

A live binding is a memoized resolution (§3.1). The following invalidate the **binding** (the
generation or epoch moves, and the next use is refused or re-resolved explicitly, §3.3):

- reloading or unloading a provider;
- restarting it;
- changing the substrate (another platform arm, another image).

None of them destroys the interface **identity** or the historical correspondence: rows and
their lineage stay, and old evidence remains attached to the artifact it was produced for.

**Exported variables** are interfaces too, but they resolve to a **storage location** with a
lifetime and access rules (read, write, atomic, which context), not necessarily to a callable
entry. Their binding is invalidated by the same events, and a stale location is refused like a
stale entry.

---

## 4. Platform arms

DRAFT 4 note: §0.1 adds three Linux-ABI routes across these arms (L1 hosted Linux, L2
Unikraft binary compatibility, L3 projected syscall table). The DoD milestones (§0.4) are
placed on them.

A platform arm is a set of providers plus the rows that bind interfaces to them. Platform arms are
selected at configure time. A program that imports nothing platform-arm-specific compiles for
any platform arm that provides its required interfaces.

| platform arm | substrate kind | binding form | status | evidence |
|---|---|---|---|---|
| Unikraft | library OS / unikernel (not a microkernel) | direct call, same address space | **exists by repo claim**; libraries exist (V) | `examples/unikraft/BUILD.md`: 164,544 B image, 2 MB RAM floor, measured 2026-08-05 on macOS/arm64 under TCG with no boot time (C). Not re-run here |
| Unikraft ELF-loader | unikernel with Linux ABI | syscall ABI | **exists by repo claim** | same file: 1,785,736 B image, 5 MB floor (C) |
| hosted (Linux/macOS process) | host OS | libc, syscalls, Zig std | **exists implicitly**: it is Koru's default Zig backend. There is no `linux/` platform namespace (V, tree) | Koru's regression suite (not run here) |
| plex-os i686 | bare metal, ring 0, Multiboot1, no paging or IDT | hand-rolled ABI struct (`PlexGuestBoot`) | **exists and measured** as a parked reference | boot and DOOM reaching E1M1 under QEMU (M, `notes/evidence/`) |
| KolibriOS | monolithic 32-bit x86 OS in FASM | `int 0x40` numbered syscalls | **donor only** (not an platform arm) | GPL-2.0 (V, `kernel/trunk/COPYING.TXT`) |
| microkernel (future) | seL4- or L4-style | service endpoint and RPC stub per row | **design only** | — |
| BSD, DOS | host OS | libc, syscalls / `int 21h` | **design only**; none exists in either repo (V, tree grep) | — |

Notes:

- **Unikraft is a library OS.** Interfaces bind to functions in one image. A microkernel
  platform arm would bind the same interface identities to endpoints instead. That is why the
  row separates `interface` from `provider.mechanism`.
- **The `unikraft` path alias is the namespace mechanism to copy** (V, `src/config.zig`).
  The source comment states the design intent: `unikraft` sits beside `std` rather
  than under `koru/` because "`unikraft/net` is the operating system the program is
  running inside". A koru-os platform arm would add an alias the same way.
- **KolibriOS is a donor, not a model.** It is in the timesharing line
  (CTSS → Multics → Unix): ring-0/ring-3 trap boundary, process slots, a scheduler in
  `core/`. koru-os stands in the Multics-segments / single-level-store / Opal / Mungi /
  unikernel line, which removes that barrier rather than reproducing it.
  - Candidate subtrees are listed in §4.1. All exist (V, listing): `blkdev/`, `bus/`,
    `fs/`, `network/`, `posix/`, `core/`.
  - Its `int 0x40` function-number table is a NID discipline in miniature: a stable
    number to a kernel function, without lineage.

### 4.1 Donor classification (KolibriOS and plex-shell)

Classes: **reuse** (take code), **wrap** (bind as a provider behind a row),
**translate** (rewrite in Koru from the reference), **behavioural reference** (use as
an oracle for tests), **reject**.

KolibriOS code is GPL-2.0 and Koru is MIT. That makes reuse and wrap of KolibriOS
code subject to licence review. Translate and behavioural reference are the default.

| candidate | class | reason |
|---|---|---|
| Kolibri `blkdev/`, `fs/` (FAT, ext2 readers) | behavioural reference, then translate | small, self-contained format logic; GPL blocks direct reuse |
| Kolibri `network/` | behavioural reference | Unikraft `lwip` plus `unikraft/net` (V) already cover the Unikraft platform arm |
| Kolibri `bus/` (PCI) | behavioural reference | needed only by a bare-metal platform arm |
| Kolibri `posix/` | behavioural reference | shows the size of a POSIX projection; koru-os wants strict shims (R-LINK-1) |
| Kolibri `core/` (scheduler, slots, traps) | reject (as a model) | the timesharing barrier koru-os is designed to remove |
| Kolibri `int 0x40` table | behavioural reference | numbering discipline, without lineage; contrast with §3.2 |
| plex-os boot + `PlexGuestBoot` | translate (as a row template) | a one-row ABI contract: struct, load address, register convention, re-entry |
| plex-os DOOM `libc_shim` (~60 symbols) | translate, made strict | a source-level projection, not syscall emulation; unshimmed must refuse at link time |
| plexd `resolve_record_id`, resolver `grounded`/`clarify` | translate | exact, then unique prefix, then ambiguous refusal, then not_found |
| plex-net `CapabilitySemantic` + pathfinder + `execute_flow` | translate | linear/invariant tokens plus a budget with explicit refusal |
| plex-net `UCANLease` | translate | DID-signed, attenuated, expiring authority; add delegation chain and revocation |
| plexd keepalive | translate | observable supervisor snapshot (up, pid, restarts, last_exit) |
| plexd store quarantine + revisions | translate | staging with one-shot promote; append-only revisions |
| plex-desktop traits | translate (names only) | `DesktopProjection`, `CompositorBridge.attach/detach` |
| plex-core quine_crypto, secure_channel, pcc, SASOS/multikernel | reject | XOR "cipher"; toy checker; hosted structs presented as an OS |

**Decisions on KolibriOS and FASM.** *Recorded 2026-10-19 about 18:40 CEST from Fabian's whitepaper analysis (ch.06/08 of `Cypoe/plex-shell` @ `f34e473f`, now readable through GitHub). Decisions are Fabian's, or a synthesis he endorsed by pasting it; the wording here is this note's.*

- **FASM dialect: no.** A FASM-derived Koru dialect will not be built:
  - (a) its untyped macro comptime would double the Transform layer and add host debt;
  - (b) it would multiply the ccomp congruence obligations;
  - (c) a raw-assembly escape already exists through `~proc|zig`.

  KolibriOS FASM is a behaviour reference and donor, not a dialect source.
- **KolibriOS is a donor for drivers, not a structural model.** It is a donor for block
  devices, buses, networking and file systems (the table above).
  - Its structure preserves timesharing: process slots, a per-process address space, rings
    and traps. That is the Garmisch 1968 discipline of *size*, not of *structure*, and koru-os
    does not adopt it.
  - Its i686 target is shared with plex-os, so the two are realization B's class (§8.7).
  - GPL-2.0: studying KolibriOS is free, but reusing or wrapping its code needs a licence
    review (Q7, Q26).

---

## 5. What Koru already provides

Status values: **V** (read now at the pinned SHA), **C** (claim carried over), **D** (missing).

| piece | location | status | what it gives koru-os | gap |
|---|---|---|---|---|
| platform alias resolution | `koru/src/config.zig` | V | `unikraft` and `koru` aliases: two install layouts tried in order, and a loud "module not found" when neither exists | no platform arm selection; aliases are path probes, not interface resolution |
| Unikraft image manifests | `koru-libs/unikraft/index.kz`, `README.md` | V | `unikraft:image` derives `addlib` plus prefixed variables from one name; `unikraft:kconfig` writes Kraftfile deltas; `koruc app.k unikraft gen` | the Kconfig is **passed through, not derived**; `CONFIG_STACK_SIZE_PAGE_ORDER: '6'` is always injected as a constant (overridable), not computed from stack demand |
| Unikraft image numbers | `koru/examples/unikraft/BUILD.md` | C | 164,544 B image; 2 MB floor; 1.5 MB fails; ~15 s build; no syscall shim, no VFS | not re-run; static archive is 2,968 B in BUILD.md vs 3,214 B in the lib README (two builds, both repo-reported) |
| known-not-done list | same file | V (as text) | `INITSCHED='n'` and `SCHEDCOOP='n'` silently ignored (99 KB of scheduler objects stay in); 41,920 B (25%) `.eh_frame` unreachable by C flags, needs linker-script `/DISCARD/`; LTO breaks the link; `DEADELIM` saves 24,832 B | exactly the first slice's job |
| Unikraft subsystem lifts | `koru-libs/unikraft/{alloc, allocpool, blk, intctlr, lock, mpi, net, ninep, pages, paging, sched, store, vmem}` | V (13 directories, each with README, index.kz, tests) | phantom-typed wrappers over `lib/uk*`, with negative tests | provider-side only; no rows, no platform arm abstraction |
| vmem | `unikraft/vmem/README.md` | V | reserve mints `<reserved!>` (costs one `struct uk_vma`); commit is the only path to backing; `release` takes only `<!used\|!frozen>`, so commit-then-release-untouched does not compile; freeze is one-way; `VADDR_ANY` and page size derived by behavioural probe | — |
| paging | `unikraft/paging/README.md` | V | real `mov %cr3` from a running Koru unikernel; `pt-set-active` accepts only `<!active-safe>`, minted only by `pt-clone`; `pt-free` never accepts an active table; boot test needs `-m 256M` (fails at 64M, measured in the repo) | singleton CR3 vs per-handle obligations: a superseded active table can never be freed (documented cost) |
| ninep | `unikraft/ninep/README.md` | V | host directory over virtio-9p; parent handle consumed by the child constructor and re-minted by its destructor, three levels deep; read and write round-trip shown | strict LIFO containment; sibling fids not admitted |
| store (Unikraft) | `unikraft/store/README.md` | V | refcounted registry lifted per binding; double release refused (`KORU030`) | **the counting wall stated by the repo itself**: "refcounting is a count; an obligation is a claim about one binding" |
| sched | `unikraft/sched/` | V (exists) | cooperative scheduler lift | not studied for this note |
| `std/supervisor` | `koru_std/supervisor*.kz` | V | `restart: N` elaborates at compile time to a bounded retry fold; N retries means at most N+1 runs; exhaustion forwards the last outcome unchanged in kind; pinned by test `320_151` (per header) | compile-time only; no runtime supervision tree, no generation counter |
| `std/bridge` | `koru_std/bridge*.kz` (grants, custody, session, world, wiregate, …) | V | durable session ("Hollywood OS mode"): HandlePool outlives runs; `create` mints `<session!>` and only `close` discharges it; scope-bound vocabulary; `bind` injection verb; world dir persistence | session is per bridge; no attach/detach of views as a named concept |
| `std/foreign` | `koru_std/foreign.kz` | V | names only, bare fields, typed fields refused (`KORU173`); inspection-only forever (ruled 2026-09-04) | by design cannot hold correspondence substance |
| `std/store` refs | `koru_std/store.refs.kz`, `store.refhome.kz`, `store.refhomeapi.kz` | V | `ref(T)` row handles with a validated target (`KORU161` on unknown) and one authority for ref homes | rows for interfaces and providers not yet modelled |
| `std/channel` custody | `koru_std/channel.custody.kz`, `channel.transit.kz`, `channel.home.kz` | V | issued obligations (`T<s!>`) transit custody through a channel, per edge | resolution is same-flow at this rung |
| `std/runtime` | `koru_std/runtime*.kz` (manifest, registry, contract, outcome) | V (exists) | scope descriptors, dispatcher, costs and obligations generated from declarations; the KoruFlow doc names it as the source | not studied in detail for this note |
| `std/rings` | `koru_std/rings*.kz` | V | Vyukov bounded MPMC rings, named statics, `\| full` backpressure branch, multicast taps | — |
| membrane / commit gate | `/workspace/koru-distill/DISCIPLINE.md` (koru@24c1538) | V (local document) | lineage verbs, `## World Model` / `## Membrane` trailers enforced by commit-msg hook | process discipline, not a runtime mechanism; reused as the lineage model for rows |
| licence | koru `README.md` says MIT | V | — | no LICENSE file in the tree, and GitHub reports `license: null`; needs confirming before any GPL comparison is final |

Not found at the pinned SHAs (V, tree grep): a `linux/`, `bsd/` or `dos/` platform namespace.
The `koru-libs/metal` library is Apple Metal plus AppKit, not bare metal.

---

## 6. Memory: single address space and the counting wall

### 6.1 Position

- **Single address space** means one coherent namespace of objects. Four properties
  are kept separate:
  - object identity
  - virtual location
  - permission
  - physical residency

  Opal and Mungi are the precedents: addressability separate from protection.
- **Metadata scales with allocated regions, not reserved address space.** This is
  already true on the Unikraft platform arm (V, vmem): a reservation of any size costs one
  `struct uk_vma`, and backing exists only after `commit`. No terabyte page-table
  pre-allocation is needed.
- **Protection domains are page tables, swapped deliberately.** `unikraft/paging` (V)
  shows a running Koru unikernel switching CR3 safely. The cost is real: a deep clone
  needs `-m 256M` where 64M fails (repo-measured).

### 6.1a One address-space regime

*Folded in 2026-10-19 about 18:30 CEST from design material Fabian supplied (authoritative guidance; the wording here is this note's).*

There is **one** coherent address-space regime per image. Allocations, mappings, permissions
and reclamation all obey it, and no subsystem keeps a private second model. Four things that
are easy to conflate stay distinct (as in §6.1):

- **object identity:** which object, stable across moves and reloads (§3.1);
- **virtual location:** where it is mapped now (a memoized resolution, §3.8);
- **permission to access it:** a rung-1 handle (§8.4), and hardware-enforced from rung 2;
- **physical residency:** whether and where backing pages exist.

**The terabyte-reservation trap.** Metadata must scale with **allocated regions, populated
translation structures and resident data**, never with every page of the hypothetical address
universe. These are five different costs and are accounted separately:

| cost | scales with |
|---|---|
| a large address namespace | nothing (it is a number) |
| an OS reservation | one region record per reservation |
| populated page tables | the mapped ranges, not the reserved ones |
| committed backing | the commitment budget |
| resident physical pages | what has actually been touched |

Starting rules (D; vmem already meets the first two on Unikraft, V §6.1):

1. sparse region metadata (one record per region, not per page);
2. lazy backing and lazy mapping;
3. explicit commitment budgets, charged at `commit`, refused when exhausted;
4. no eager per-page bookkeeping for untouched ranges;
5. transactional updates to the region and protection model: a multi-step change (split, remap,
   permission change) is applied completely or not at all;
6. a defined failure when backing cannot be provided (a refusal branch at commit or a defined
   fault outcome), never a silent overcommit.

### 6.2 What is proven and what is not

isar-proofs `Kernel.lean` proves SKI/ITerm confluence (read, Task 1). It does **not**
verify any single-address-space property: `CapAddress`, `UPageRing` and
`DirectMemoryDescriptor` exist only as hosted Rust structs in plex-core. The proof
corpus also contains explicit `axiom`s, which the whitepaper's "0 sorry" framing omits.
koru-os must not cite the whitepaper as evidence for single-address-space safety.

### 6.3 The counting wall

Phantom state tracks obligations **per binding**. Three verified specimens show where
that is insufficient:

1. **Refcounts.** `unikraft/store` (V): N holders of one object are N independent
   `<held!>` bindings. The type system does not know the count and cannot tell the
   last release from any other. The repo states this as the ceiling of the per-binding
   model.
2. **Singletons.** `unikraft/paging` (V): one CR3 register, many `<active!>` handles. The
   lift chooses conservative over wrong, so a superseded table can never be freed.
3. **Sibling sharing.** `unikraft/ninep` (V): consume and re-mint gives strict LIFO
   containment. Sibling children of one parent (two open files under one root) are not
   expressible without counting.

Plus three plex-shell counter-examples (read): the pathfinder's set state loses
multiplicity; `MEM_REGISTRY` hands out name-addressed `Arc<Mutex<Vec<u8>>>` regions with
refcount lifetime and no revocation; `delegate_capability` copies, with no count and
no revoke.

### 6.4 Proposed direction (D)

- **Immutable, snapshot-addressed regions are shared without counting.** Content-addressed,
  frozen regions (vmem `freeze` is already one-way) can be aliased freely. Sharing them
  is confluent: no reader can observe another reader. Their lifetime is a store-side
  reachability question, not an obligation.
- **Mutable regions use counted, revocable capabilities held by the store.** The store,
  not the type system, owns the count and an epoch per region:
  - a binding carries `(region, epoch)`;
  - revocation increments the epoch;
  - a stale epoch is refused at use (the same rule as a stale `generation` in §3.3).
- **Phantom state keeps doing what it does well.** It enforces that each binding is
  released exactly once. The store answers "how many" and "still valid".
- *Closed at the design level (D), 2026-10-19 about 18:40 CEST.* Fabian: "Zähl Mauer wir hier
  schon beantwortet haben." The design answer is §8.5. Revocation goes through indirection (Redell),
  not through counting holders: an epoch per store-held slot, plus leases. Counting returns only
  for reclamation, answered by epoch plus quiescence (RCU-like), and frozen regions need neither.
  Still owed: **measurement (M)** against the three verified specimens (§6.3), as a spike inside the
  SASOS ascent (§11.5). Until measured it is D, not V or M.

---

## 7. Session model (headless, with detachable views)

The desktop is a **session model**, not a renderer. The session holds:

- apps
- services
- workspaces
- grants
- connections
- jobs
- notifications

Views (TUI, WebView, Qt/Quickshell, a 9P mount) are projections that attach to and
detach from a session.

*Folded in 2026-10-19 about 18:35 CEST from Fabian's second paste (authoritative guidance; the wording here is this note's).*

More precisely, the session holds:

- running apps and services;
- workspaces and selected objects;
- resource grants and live connections;
- jobs, notifications and failures;
- optional presentation surfaces.

A **window is a view attached to an app or object**. It is neither the app's identity nor its
lifetime. The renderers are detachable projections:

```
session ──► terminal | web view | local compositor
```

**Operational test.**

- Disconnect every renderer, and apps, jobs and resources continue, and so does the session.
- Reconnecting reconstructs a view from session state.
- A renderer is not a privileged owner of the desktop.
- The shell must be useful **without graphics**; that is the foundation, and graphics are a
  view on top of it.

A local compositor (Hyprland in M9) is therefore one renderer among several, not the desktop.

Existing pieces:

- **`std/bridge` (V).** A durable session with a scope-bound vocabulary. Handles and
  obligations outlive individual runs, and the session itself is an obligation
  (`<session!>`, discharged only by `close`). This is the core of the model.
- **plexd (read).** "Daemon-first truth": the daemon owns sessions in SQLite, and plexsh,
  HTTP, WebView and Qt are disposable projections (plex-shell decision 002). It also
  shows the gap. `SessionOpen` always creates a new session; there is no attach, and
  job survival after client disconnect is accidental.
- **`unikraft/ninep` (V).** A plan9-style namespace mounted from the host: the natural
  session surface for a headless platform arm, where a view is a mount.

Required behaviour (tested in §11):

- `attach(session_id)` and `detach(view)` are explicit operations with outcomes. On an
  unknown session, attach returns `not_found`; it never silently creates one.
- Jobs and services have a lifetime owned by the session, not by any view.
- **The test of the model:** disconnect every renderer and all jobs continue. Reattaching
  a new view observes the same session state and the job output produced meanwhile.

---

## 8. Security target model: silos, capabilities, unforgeable identities

The plex-shell documents describe a model they consider more secure than the
timesharing one. koru-os adopts it as a **target**, under a different realization.

- Appendix A has the claim-by-claim comparison of docs and code.
- This section states the result and the koru-os design.

### 8.1 What the plex docs aspire to (C)

Read in full: whitepaper ch.00, 03 and 06; architecture manual 00–07;
`PLEXUS_UNIFIED_THESIS.md`; `WHITEPAPER_AUTOMATIC_SYSTEMS_PROGRAMMING.md`; `ARCHEOLOGY.md`;
the KoruFlow protocol doc.

- **App silos.** "An isolated capability-bounded container for external processes
  featuring immutable snapshot baselines and non-destructive atomic rollbacks." An
  update is "an atomic snapshot pointer swap; if health checks fail, the silo rolls back
  instantly" (thesis §6.2, glossary).
- **Capability tokens instead of privilege rings.** SASOS is "eliminating MMU page-table
  swaps (CR3 traps) and dual-mode kernel/user context switches" (glossary, ch.06). Legacy
  runtimes "execute inside `AppSilo` boundaries" (thesis §4.2).
- **PCC instead of sandboxes.** "replaces software sandboxes (Wasm, JVM, Docker) with
  Proof-Carrying Code". It claims verified invariants for memory bounds, "capability grant
  safety: invoked hardware capabilities are strict subsets of the calling silo's UCAN
  grant", and termination (ch.03 §2).
- **UCAN leases.** "Cryptographically signed UCAN delegation chains with resource
  attenuation, TTL expiration" (Automatic Systems Programming whitepaper §8.5).
- **Non-hierarchical capability addressing.** `CapAddress {Ring, Snapshot, Capability,
  Port, Tensor}` replaces paths (ch.06 §2).

**What the docs do not name** (V, grep over all fetched docs): CHERI, Morello,
MPK/PKU, or any hardware-enforced capability. "Hardware capabilities" in ch.03 means
authority over hardware resources, not hardware-enforced capabilities. `TaggedWord`
tags are 3 software "ontological" bits.

The docs **reject** page-table protection rather than use it. koru-os's rung 2 and
rung 3 (below) are therefore additions, not inheritances.

### 8.2 What plex code does (V, plex-shell @ `f34e473f`)

- **Forgeable addressing.** `CapAddress` is a public enum of strings and integers.
  `SubstrateKernel::resolve_address` is a `HashMap<CapAddress, u64>` lookup: anyone who
  can spell the value gets the offset. There is no permission field, so it is a name
  table, not a capability.
- **Authority is strings.** `TensorSubgraph.capabilities` is a `Vec<String>`.
  `delegate_capability` checks that the source holds the string, then pushes a copy to the
  target. There is no attenuation, no count, no revocation and no record of who granted it.
- **Silo rollback does not roll anything back.**
  - `MultikernelHypervisor::rollback_silo` returns the stored checkpoint metadata, and
    `checkpoint_silo` hardcodes `timestamp: 1000`. No memory is copied or restored.
  - In plex-desktop, `update_silo` overwrites the version unconditionally (no health
    probe), and `launch_silo` returns a mock PID.
  - plexd `silos.rollback` returns canned JSON.
- **PCC is a string rule checker.** `pcc.rs` checks premise counts over string
  conclusions. It is not connected to Lean and checks no memory bounds.
- **UCANLease is the one real piece.**
  - What works: an ed25519 DID signature, audience, verbs, path-prefix attenuation and
    expiry. The refusals are tested (M: passed).
  - Missing: a delegation chain (no parent reference), and revocation other than expiry.
  - Weakness: the signed payload is a `:`-joined string with no escaping, so field
    boundaries are ambiguous (H: possible canonicalization confusion).
  - `ARCHEOLOGY.md` says HMAC/SHA-256, but the code uses ed25519.
- **Documented file that does not exist.** Manual ch.03 lists `ephemeral.rs` ("subagent
  sandbox session isolation"); no such file is in the tree.

### 8.3 What Koru already provides toward it (V)

- **Compile-time unforgeability inside one program.** Phantom obligations are types. A
  `<state!>` value can be obtained only from a tor that issues it. A discharged binding
  cannot be reused (`KORU030`). An undischarged one cannot be dropped (no implicit drop,
  per the matrix).
  - This holds for Koru-authored code only. A `proc` host body (Zig/C) can construct any
    bit pattern, so host bodies are inside the TCB.
- **Grammar-enforced unauthorability.** The matrix's `unauthorable` (`.marks`) is the
  precedent for "a value the object language cannot construct".
- **Scope-bound vocabulary.** `std/bridge`: a session acts only through the tors of its
  scope; anything outside it is denied. Discharge is dispatched through the scope.
- **One-way freeze.** `unikraft/vmem`: `freeze` moves a region to read-only with no
  thaw. This is the basis for snapshot baselines.
- **Domain switch primitives.** `unikraft/paging`: page-table clone and a CR3 switch
  from a running Koru unikernel, with "never free the active table" enforced. This is the
  basis for rung 2.
- **Names-only FFI.** `std/foreign` registers names only. Substance stays with the host,
  which makes the TCB boundary visible in source ("every `std/foreign` line is searchable
  host debt").

### 8.4 Design: a ladder of enforcement rungs

Each platform arm declares the highest rung it can enforce. Each correspondence row
declares the lowest rung its provider needs. Binding a row on an arm that cannot meet
the row's rung is a configure-phase refusal.

| rung | mechanism | unforgeable against | revocation | platform arms (status) |
|---|---|---|---|---|
| 0 | compile-time obligations; single trusted image | Koru-authored code only; the whole image (every `proc`, every C library) is TCB | none at run time; rebuild | Unikraft, plex-os (exists, V/M) |
| 1 | **minted handles at the binding seam**: a live binding is a resolver-minted handle `(row, slot, generation/epoch)`, never a raw pointer or a name; across images, a signed token with a delegation chain | Koru code inside the image; any party across a trust boundary (cryptographically) | lease expiry (minimum); epoch bump; revocation list for cross-image tokens; revoking a parent revokes descendants | all platform arms (D) |
| 2 | **page-table protection domains in one address space** (Opal/Mungi): one virtual namespace, one page table per domain mapping only granted regions; cross-domain calls through a gate that checks the rung-1 handle | code in other domains, including host code in an untrusted domain | unmap plus TLB shootdown plus epoch bump | Unikraft via `unikraft/paging` (primitive exists, V; domains D); hosted via processes (D) |
| 2′ | x86 MPK/PKU as a cheaper intra-table variant | only if untrusted code cannot execute `WRPKRU` (needs binary inspection, as in ERIM/Hodor; C) | key reassignment (16 keys) | D; candidate only |
| 3 | **hardware capabilities** (CHERI: Morello, CHERIoT): bounded, permissioned, tagged pointers; sealed capabilities implement rung-1 handles in hardware | all code, including C providers in the same domain | revocation sweep (CHERIvoke/Cornucopia-style, C) or epoch-checked sealed handles | D; depends on toolchain support (§12) |

**Unforgeable identity vs PS NIDs.** A PS4/PS5 NID is a name hash. Anyone can compute it,
so it identifies but carries no authority (C). A koru-os rung-1 handle has three parts:

- the minted interface identity (§3.1),
- an authority set (verbs or tors of a scope, plus attenuation),
- a generation or epoch.

It can be obtained **only** from the resolver's mint. The NID hash remains the cheap
comparison key in the row; the handle, not the hash, is what grants a call.

**Silos are the isolation unit for untrusted or foreign providers.** A silo is a
protection domain (rung 2 or higher), or on the hosted arm an OS process or VM, with:

- **Immutable baseline:** a frozen, content-addressed snapshot (vmem `freeze`; §6.4).
- **Update:** build a new frozen snapshot, then take the health-probe obligation. Only
  its discharge with `ok` swaps the snapshot pointer.
- **Rollback:** re-point to a previous frozen snapshot, restoring **content**, not metadata.
- **Boundary:** all calls cross a rung-1 gate. Grants into the silo are attenuated
  handles, and every grant is recorded.

**FFI rule.** An unchecked foreign provider (a `proc` host body, a C library, a
syscall) either sits **inside the declared TCB of the image**, listed in a TCB manifest
with evidence, or sits **behind a silo boundary**. It never sits silently in a trusted
domain. On rung 0 and rung 1 platform arms the only option is the TCB manifest.

### 8.5 Revocation and the counting wall

Revocation requires reaching every holder or interposing an indirection. koru-os uses
indirection, so revocation does not require counting holders:

- **Every handle names a store-held slot that carries an epoch.** Revoking increments
  the epoch, and every holder fails at its next use with `revoked`. This is Redell's
  caretaker or revoker pattern (C), the same rule as stale `generation` in §3.3.
- **Leases bound authority in time.** They are the minimum mechanism on every rung and
  across trust boundaries (UCANLease shape plus a parent link).
- **Revocation lists** exist only for cross-image tokens that cannot reach the store.
- **Counting comes back only for reclamation:** freeing or reusing a revoked mutable
  region needs to know that no holder can still touch it.
  - Epoch plus quiescence (an RCU-like grace period) answers that without per-holder
    counts.
  - Frozen snapshot regions need neither counting nor revocation for safety (§6.4).
  - This is the concrete form of the counting-wall question (§12).

**Status: this subsection is the design answer to the counting wall** (closed at the design
level 2026-10-19 by Fabian, §6.4, §12 Q1). There is no N-holder count for revocation. The open
part is measurement only.

### 8.6 Spawn: minting a child (a dissected fork)

*DRAFT 2026-10-19 18:20–18:45 CEST, written after Fabian's ruling on Q29. Everything in this
section is design (D) unless a sentence carries another class. No code exists yet and nothing
here has been measured.*

**The ruling (Fabian, 2026-10-19 about 18:20 CEST), restated:**

1. M9 is **not** passed and stays open. The Spawn design comes first.
2. No wholesale POSIX `fork`. Fork as a library has to be **dissected**: ownership,
   provenance and rights stay visible, and a child does not inherit all rights unless they are
   explicitly granted. An opaque fork is a bad fit for obligations and NIDs.
3. The library's home is **koru-libs** (the `Cypoe/koru-libs` fork of `korulang/koru-libs`,
   whose `unikraft/` already holds `sched`, `blk`, `vmem`, `paging`, …). This is probably also
   the home of the recent OS lifts. Unikraft's `vfork`/`execve` may stay as a thin, **loud**
   compatibility layer under that model; it is not the model.
4. Upstreaming a dissected spawn or fork to Unikraft or korulang is a later, separate ask.
   Fabian has already named fork as a good upstream candidate once it is dissected.

#### 8.6.1 What `fork` bundles

`fork()` is one call that makes about a dozen separate decisions, all of them implicitly and all
in favour of "copy everything". `execve()` then makes a few more. Spawn takes each decision
apart and makes it a separate, recorded step. The left column is POSIX (C, POSIX.1-2024 and
Linux man pages); the right column is the Spawn rule.

| # | what `fork`/`exec` decide implicitly | Spawn rule | Unikraft 0.21 today |
|---|---|---|---|
| F1 | a new identity (pid), never named in advance | the child identity `{instance, generation}` is **minted** by `reserve`, before anything runs, and is never reused | pid from posix-process (V) |
| F2 | a copy of the whole address space (COW) | **refused, not grantable** on every arm. The child starts at an image entry point; nothing continues in two contexts ("returns twice" does not exist) | refused: `clone` without `CLONE_VM` → "Multiple address spaces are not supported" (V, B20) |
| F3 | a copy of the whole fd table | **nothing inherited.** Every fd the child sees, 0/1/2 included, is a grant | the vfork child gets its own fd table (V by behaviour: hush pipelines and redirections work, M3/M5) |
| F4 | credentials (uid/gid/capabilities) | **no ambient credentials.** Authority is only what the bag holds; the compat layer may *report* uid 0, it grants nothing | single user, everything is root (V) |
| F5 | the environment | **no variable inherited.** Each variable is a grant (name and value recorded) | copied by `execve` from `envp` (V) |
| F6 | cwd, root, umask | the child's path resolution starts at a **granted directory handle**; no ambient `/` | one global vfs (V) |
| F7 | signal dispositions and mask; the right to signal others | the child may signal nobody. The parent's only power over the child is the verb set on its child handle (`kill` is a verb). SIGCHLD becomes the completion of the parent's obligation | uksignal; SIGCHLD into a vfork parent crashes (B22) |
| F8 | the parent/child relation: `wait`, reaping, zombies, reparenting to init | **reaping is an obligation** of whoever holds the child handle. Reparenting is an explicit `detach` to a named supervisor, never a side effect of a parent's death | posix-process `wait4` (V) |
| F9 | the right to spawn again | not inherited. A child spawns only with an **attenuated spawn authority** in its bag (allowed images, maximum bag, maximum number of children) | anything may vfork (V) |
| F10 | shared memory: `MAP_SHARED` regions, SysV shm, memfds | none, except frozen snapshot regions (§6.4, free to share) and explicit grants of a mutable region, recorded on both sides | one address space: everything is reachable (V) |
| F11 | session, process group, controlling tty | only through a granted pty handle (with the verbs that make it a controlling tty) | korupty + posix-process groups (V, M9 probe 8) |
| F12 | `exec`: replace the image, keep the fds without `CLOEXEC`, reset the handlers | `replace` is a verb the child needs in its bag ("may become an image in set S"). Grants **do not** survive exec unless marked `across_exec`. This inverts the POSIX default, where `CLOEXEC` is the opt-out | app-elfloader `execve` (V); stack size B12 |
| F13 | `pthread_atfork` handlers, lock state, other threads | not applicable: nothing is copied, so there is no lock state to repair | — |

#### 8.6.2 The model: a child is minted with an explicit rights bag

A **child** is a record in `std/store`, not a pointer:

```
child {
  identity:   { instance, generation }          -- minted by reserve, never reused (F1)
  image:      { artifact, closure[] }            -- content hash of the program + its loader
                                                 --   closure (ld.so, DT_NEEDED), read+exec only
  requires:   [ interface ]                      -- the image's imports (its NIDs, §3.1)
  bag:        [ grant ]                          -- frozen by seal
  lineage:    { parent: instance, verb: create (spawn) | evolve (replace) }
  supervisor: holder of the reap obligation      -- the parent, or a named supervisor after detach
  manifest:   evidence ref                       -- table emitted at seal (8.6.5)
}

grant {
  handle:     { row, slot, epoch }               -- a rung-1 handle (§8.4), never a raw fd or pointer
  verbs:      subset of the parent's verbs on it  -- attenuation only, never amplification
  as:         { scheme, name }                    -- how the child names it: linux.fd 0, env WAYLAND_DISPLAY,
                                                 --   path /run/xdg/wayland-1, ...
  provenance: { granted_by: parent identity, from: parent handle, at, why }
  lease:      <= the parent's lease on the same handle
  across_exec: bool                              -- default false (F12)
}
```

The grants **are** correspondence rows in the sense of §3.2. The `foreign` side is how the child
names the right (fd 3, `$WAYLAND_DISPLAY`, `/usr/share/fonts`). The `interface` and `provider`
sides are the parent's handle. Lineage records who granted what. The evidence field holds the
seal manifest. A child's imports resolve **only** against its bag plus a short **ambient set**
that every child gets without a grant. The ambient set is listed and kept small:

- its own memory within the bag's page budget;
- reading the monotonic clock;
- `exit`;
- yield.

Anything else that the image imports and that the bag does not cover is a refusal: at `seal`
when the image's imports are known statically (the configure phase, §3.4), otherwise at the
first call (the run phase). The refusal has the fixed shape (§3.4).

**Phantom states**, in the shape of `unikraft/sched`. Each state is minted only on evidence, as
`<ran!>` is there:

| tor | takes | mints | meaning |
|---|---|---|---|
| `reserve` | a spawn authority, an image ref | `<staged!>` | identity minted, image hashed and its closure resolved; nothing runs |
| `grant` | `<!staged>`, a parent handle, verbs, name, lease | `<staged!>` | one grant appended to the bag, with provenance; refused if the verbs exceed the parent's |
| `seal` | `<!staged>` | `<sealed!>` | bag frozen; imports checked against bag + ambient set; manifest emitted |
| `start` | `<!sealed>` | `<running!>` | **only on evidence** that the child executed its entry (a flag set by the child's first instruction, as in `sched:run`); otherwise `\| stalled` and the handle stays `<sealed!>` |
| `wait` | `<!running>` | `<exited!>` + status | |
| `reap` | `<!exited>` | — | the record is retired; slots and pages are reclaimed |
| `detach` | `<!running>`, a supervisor handle | — | the reap obligation moves to the named supervisor (Hyprland's "leave it to init"); greppable |
| `abandon` | `<!staged\|!sealed>` | — | the child never ran; the escape, named for what it is |
| `revoke` | a grant in a live child's bag | — | epoch bump (§8.5); the child's next use fails with `revoked` |
| `replace` | `<!running>` held by the child itself, an image ref | `<running!>` | exec: requires `replace` for that image in the bag; keeps only `across_exec` grants; lineage `evolve`, generation + 1 |

There are two disposals for a live child (`reap` after `wait`, or `detach`) and a third for one
that never ran (`abandon`). That is deliberate: B5 found that `koruc` auto-discharges an
obligation that has exactly one disposal, so a leaked child (a zombie) is a compile error only
if there are at least two.

**What is refused by default** (grantable only explicitly; F-numbers from the table above):

- every fd, including stdin, stdout and stderr (F3). There is a convenience grant `stdio(a, b, c)`,
  but it is still three recorded grants;
- every environment variable (F5);
- every path: no ambient root or cwd (F6). The image closure is the one read+exec grant that
  `reserve` makes, and it is listed;
- signalling anyone (F7);
- spawning (F9);
- every mutable shared region (F10);
- tty control (F11);
- sockets and endpoints: a connect right names one endpoint, never a directory.

**What is refused on every arm and cannot be granted:**

- copying an address space (F2);
- continuing at the caller's instruction pointer in a second context;
- amplification: a grant with verbs the parent does not hold;
- a lease longer than the parent's own;
- reusing a child identity.

**What the rung means here (honesty; see also 8.6.8 and §6.1a).** On rung 0 and 1 (Unikraft today: one address space, one
page table, cooperative scheduler) the bag is enforced **at the binding seam**: the syscall shim,
the fd table and path resolution. A child that ignores the seam can still read any memory of the
image, and nothing preempts a child that spins (B22). So on these rungs Spawn is a
**provenance and correctness boundary, not a security boundary**: every right is named, recorded
and revocable for code that goes through the seam. Containing a hostile child needs rung 2 (one
protection domain per child, §8.4, `unikraft/paging`). The model and the tors stay the same; only
the enforcing rung moves up. The manifest states the rung at which each bag is enforced.

#### 8.6.3 How exec fits

There are two cases:

- **Spawn of a new image.** `reserve` names the image. This is the only way a new program starts.
  `posix_spawn` and `vfork`+`execve` map onto it (8.6.4); "fork then exec" collapses into it.
- **A running child replaces its own image** (`execve` without `vfork`, e.g. `exec foot` in a
  script, or busybox re-executing itself). This is `replace`: the identity stays, the generation
  goes up, the artifact changes, and lineage says `evolve`. The new image's imports must be
  covered by the surviving bag, or `replace` refuses **before** the old image is torn down. This
  is unlike POSIX, where a failed exec after the point of no return kills the process.

Signal handlers, timers and threads never survive `replace`. Memory is the new image's, plus
only those frozen regions that are granted `across_exec`.

#### 8.6.4 The compatibility layer (Linux ABI on L2): thin and loud

The layer translates Linux process calls into Spawn calls. It runs inside the image (koru-os
`lib/`, C, until the Koru lift has a C-ABI entry). Every translation it makes prints one line
(`spawn-compat: …`) and records a manifest row. "Loud" means that every right the layer grants
because POSIX would have inherited it is **visible** as such (`provenance.why = posix-inherit`),
never silent.

| Linux call | translation | what stays refused |
|---|---|---|
| `posix_spawn(path, file_actions, attrs, argv, envp)` | `reserve(path)`; then one grant per fd that is open and not `CLOEXEC` after the file actions (each `why = posix-inherit`, or `why = file-action` if a file action named it); one grant per `envp` entry; `seal`; `start`. `POSIX_SPAWN_SETSID` / `SETPGROUP` need a tty or group grant | fds beyond a per-image limit; env beyond the policy list (a policy row may narrow `posix-inherit` to a listed set) |
| `vfork()` … `execve()` | the vfork child runs in the parent's context as today, and is **not** yet a Spawn child. At `execve` the layer does `reserve` + grants from the then-current fd table and `envp` + `seal` + `start`, and the parent resumes. `_exit` before `execve` is `abandon` | anything the child does to shared memory between `vfork` and `execve` is the caller's risk, as in POSIX; it is logged as `vfork-window` (B11, B22 live here) |
| `clone` without `CLONE_VM`, `fork()` | **refused** (`ENOSYS` plus a refusal row), as now | a fork-as-vfork opt-in is deliberately **not** offered: see the Hyprland note below |
| `execve()` outside a vfork window | `replace` | as 8.6.3 |
| `wait4` / `waitpid` | `wait` + `reap` on a held child handle | waiting on a pid the caller does not hold: `ECHILD` + row |
| `kill(pid, sig)` | a verb on a held child handle | a pid not held: `EPERM` + row |
| `setsid`, `setpgid`, `TIOCSCTTY` | need the matching grant | otherwise `EPERM` + row |

The layer is under the model, not beside it. A Linux program cannot reach a child except through
`reserve`/`seal`, and every right a Linux child holds appears in a manifest.

#### 8.6.5 Hyprland's `dispatch exec` and foot

**What Hyprland does today (C, source read 2026-10-19).** The executor logs "Fail to fork" (V,
B20). hyprutils `CProcess::runAsync` (`src/os/Process.cpp`, `main` branch) does a **double fork**:

1. The child resets its signal mask and forks the grandchild.
2. The grandchild calls `setenv` for each variable, `dup2`s the stdio fds and calls `execvp`.
3. The child writes the grandchild's pid into a pipe and `_exit`s.
4. The parent reads the pid and reaps the child, leaving the grandchild to init.

Whether 0.56's `hl.dsp.exec_cmd` reaches this code or Hyprland's own spawn path is still to be
read from the 0.56.2 source. Either way it is fork-then-exec with work between the two.

**Why fork-as-vfork is not offered.** Under vfork semantics the grandchild's `setenv` and
`strdup` would write into **Hyprland's** heap and `environ`. Every `exec` would mutate the
compositor's environment, and a failed exec would leak into it. That is exactly the opaque shared
state the ruling excludes.

**Stage 1 (compat, the path that can close M9's (h2)).**

- Patch the executor, a small patch to hyprutils and, if separate, to Hyprland. Replace the
  double fork with one `posix_spawn` that carries an explicit `envp` and explicit file actions, and
  then `detach` the child to init. "Leave it to init" becomes the recorded `detach`.
- koru-os supplies a **policy row** `hyprland.children`, the bag every Hyprland child may receive:
  - stdio to Hyprland's log or `/dev/null`;
  - connect to the one Wayland socket;
  - `XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY` and `HYPRLAND_INSTANCE_SIGNATURE`;
  - read on fonts, fontconfig and `/etc`;
  - the image set `{foot}`;
  - a spawn authority for foot's own child, limited to the image `/bin/sh` with a bag of the
    pty slave.
- foot forks its shell after setting up the pty slave (B21). The same treatment applies: foot's
  spawn is `posix_spawn` with `SETSID` and the slave as fds 0–2 (a patch to foot), under the
  attenuated authority it was granted.

  This is **nested attenuation**: Hyprland ⊇ foot ⊇ sh. Each level can only narrow. The manifests
  form a chain whose lineage the acceptance can check.
- `--pty=/dev/korupty0` remains the M9 probe workaround (B21) until then.

**Stage 2 (native).** Hyprland holds no spawn authority of its own. It sends a spawn request (an
image ref and a requested bag) to a **supervisor** (init on koru-os). The supervisor checks the
request against `hyprland.children`, mints the child and returns only a `wait`/`kill` handle.
This is the shape in which a compositor cannot start anything its policy does not name.

#### 8.6.6 Evidence

Classes as everywhere in this note (V verified by reading or running, M measured, C carried
claim, D design). L1 (hosted Linux) is an oracle and trace source only and never counts (Q17).

- **Compile-time (V once built):** the sched-style gates.
  - `koruc --check` passes.
  - Negatives refused with `KORU030`:
    - `start` without `seal`;
    - `grant` after `seal`;
    - `reap` without `wait`;
    - a leaked child (a dangling `<running>` handle);
    - `replace` called with the parent's handle.
  - A positive control: an `abandon` escape that compiles.
- **Run-time (M, under TCG, 3/3):**
  - a child prints its fd census (`fcntl(F_GETFD)` over 0..1023) and its environment, and both
    equal the bag exactly;
  - a revoked grant fails with `revoked` at its next use;
  - an amplifying grant is refused at `grant`;
  - a `replace` into an image whose imports the bag does not cover is refused, and the old image
    keeps running;
  - the roster brackets the run (`n → n+1 → n`) and no zombie remains after `reap`;
  - the manifest emitted at `seal` equals the requested bag.
- **Compat (M):**
  - every `spawn-compat:` line names the call, the image hash and the grants, with `why`;
  - a `fork()` is refused with a row;
  - for the Hyprland stage 1 chain, the manifests Hyprland → foot → sh are present, each a subset
    of its parent's.
- **Per-milestone:** M9 (h2) as frozen is met only when the frozen trigger
  (`hyprctl dispatch exec foot`) starts foot through Spawn (stage 1 or 2), measured 3/3, with
  the regressions. The (h2) wording is **not** amended (Q29 ruling).

#### 8.6.7 Where the code lives

| part | home | why |
|---|---|---|
| the Spawn interface: child record, grant, manifest, tors, phantom states, refusal shapes | **koru-libs** (`Cypoe/koru-libs`), arm-independent | the model belongs to the ecosystem, not to one OS; identity is not location (§3.1) |
| the Unikraft provider (`unikraft/spawn`): binds posix-process process creation, the per-process fd table and app-elfloader's image loading, with a layout proof and an `UK_ASSERT` census as in `unikraft/sched` | **koru-libs** `unikraft/spawn` | a lift of Unikraft primitives, no koru-os policy. Q32 (2026-10-19): a local fork of the load path lives in koru-os `lib/koruelf` (see `experiments/spawn-elf/`); app-elfloader remains an application upstream |
| a hosted provider (`posix_spawn`, `pidfd`, `close_range`) | koru-libs, later | an L1 oracle for the semantics, never a pass |
| the compat layer (8.6.4), C | **koru-os** `lib/koruspawn` (later, calling the lift through a C-ABI seam such as `tests/wrapper.zig`) | Linux-ABI personality policy: what "loud" prints, which `posix-inherit` is allowed |
| policy rows (`init.children`, `hyprland.children`, foot's attenuation), the Hyprland/hyprutils/foot patches, acceptance runners | **koru-os** | per-image policy and DoD evidence |
| the local Unikraft 0.21 patches | koru-os, until upstreamed | upstreaming is a separate ask (ruling 4) |
| the recent OS lifts (`korumemfd`, `korupty`, `korusnap`, `korusysfs`, `koruinput`, `korukms`, `koruext2fs`) | candidates for koru-libs `unikraft/*` | they are C today. Moving one means re-lifting it in Koru with phantom states and gates, not copying it. Order and criteria are Q33 |

*2026-10-19 19:33–19:37 CEST:* a measured skeleton of the Spawn interface now exists as `koru/spawn/index.kz` (`koruos/spawn`, koru-libs shape, in koru-os). It covers `reserve`/`grant`/`seal`/`start`/`wait`/`reap`/`abandon`, with empty-by-default rights and loud refusal of address-space copy (F2) and over-grant. S1–S11 and R pass 3/3 under TCG, and regressions pass 3/3 (`experiments/spawn/`). The Unikraft provider, the hosted provider and the compat layer are still not code. Nothing has been pushed to `Cypoe/koru-libs`:
it is another remote, and this work's push authorisation covers `Cypoe/koru-os` only. Upstream
(Unikraft, korulang, hyprwm, foot) is untouched.

#### 8.6.7a Result: first measured skeleton (2026-10-19, M under TCG)

The acceptance (`experiments/spawn/ACCEPTANCE.md`) was frozen in `8dae7ec` before the counted runs.

- **Boots:** S1–S11 and R pass in 3/3 boots of one image.
- **Compile gates:** `start` on staged, `grant` after `seal`, `reap` on running, and a leaked child are KORU030.
- **Checker mutation:** the checker catches the mutations (S1, S3).
- **Regressions:** Slice A, DS0 and NID+L1 pass 3/3.
- **Rung 0/1:** the child is an entry in the same image and runs to completion inside `start`, and the bag is enforced at the `ChildCtx` seam, not by the MMU.
- **Slice A** keeps its supervisor stand-in. The mapping is in `experiments/spawn/README.md`.
- **Still open:** M9 is not passed, Q30 and Q33 stay open, and Q19 → DoD-2 stays closed as ruled ("only after Spawn-lib acceptance"). Spawn-lib acceptance by Fabian is still pending. This skeleton is not that acceptance.
- **Concordance:** the new terms are proposed only.

#### 8.6.7b Result: Unikraft provider + loud compat + external ELF (2026-10-19, M under TCG)

- **Koru lift** (`koru/spawn`): `replace` (rights die unless `across_exec`), `detach`,
  `revoke` (epoch, §8.5), nested attenuation (`authority-of`). S1–S13 PASS 3/3.
- **Unikraft provider** (`lib/koruspawn`) + **ELF load fork** (`lib/koruelf`, Q32): an
  external static-pie ELF is started via Spawn with an explicit rights bag. E0–E12 PASS
  3/3 under TCG (`experiments/spawn-elf/`).
- **Loud compat** (§8.6.4): `spawn-compat:` lines for `posix_spawn`, `vfork+execve`,
  `fork` (refused), `execve`→`replace`. Fork stays refused (F2).
- **Seam:** proxy fds check verbs and epoch; vfscore `task_conv`/`taskat_conv` call
  `koru_vfs_path_gate` (patch; weak declaration, strong definition in koruspawn).
- **Not done:** M9 / Hyprland (Q30), moving the provider to koru-libs (Q33), the fd
  census via `fcntl` as the sole evidence class (the child prints its own census).
- **Concordance:** new terms proposed only.

#### 8.6.8 Relation to the execution contract and the address-space regime

*Folded in 2026-10-19 about 18:30 CEST from design material Fabian supplied (authoritative guidance; the wording here is this note's).*

- **The bag draws on interface descriptors.** Every grant names a row whose interface
  descriptor (§3.6) fixes the permitted effects and the required authority. A grant can carry at
  most the authority that descriptor allows **and** that the parent holds from an authorized
  provider (§3.0). The seal check (8.6.2) is binding admission (§3.6) applied to the child's
  imports.
- **Spawn and replace invalidate bindings, not identities** (§3.8). `replace` moves the
  child's generation. Its old bindings are refused, and the child's identity and lineage stay.
- **Address-space copy stays non-grantable** (F2). In the one address-space regime (§6.1a) a
  copy would create a second, unaccounted model of the same objects.
  - A child gets **its own regions** under the parent's commitment budget: the bag's page budget
    is a commitment budget (§6.1a rule 3).
  - The child shares only frozen regions (§6.4) or explicitly granted mutable ones.
- **Rungs.** On rung 0/1 a child's virtual location is reachable and only the binding seam
  checks permission (8.6.2, "honesty"). **Rung 2 protection domains are where virtual location
  and permission to access become hardware-enforced**, as separate facts (§6.1a), for each child.
- **Two obligations hold for children too** (§3.7). That `unikraft/spawn` compiles and passes
  its gates is evidence about the lift. It is not evidence that a Linux program in a Spawn child
  behaves.

### 8.7 Whitepaper and koru: complementary, not competing

*Recorded 2026-10-19 about 18:40 CEST from Fabian's whitepaper analysis (ch.06/08 of `Cypoe/plex-shell` @ `f34e473f`, now readable through GitHub). Decisions are Fabian's, or a synthesis he endorsed by pasting it; the wording here is this note's.*

**Synthesis.** The whitepaper's ch.06 `CapAddress` supplies the **canonical identity side**.
Koru supplies the realizations:

- **realization A:** the koru-libs Unikraft lifts. They write receipts: gates, measured tables
  and refusal logs;
- **realization B:** plex-os on i686 (M0).

**Correction carried from the earlier study** (`notes/plex-os-study.md` §4 and §7 item 4).
"Kernel.lean is the canonical identity of `CapAddress`" is wrong as stated:

- `CapAddress` is a hosted Rust enum in `plex-core/src/unikernel.rs`;
- a grep of all 55 `.lean` files finds no `CapAddress` and no SASOS;
- what `Kernel.lean` proves is SKI/ISAR confluence (`IRed_confluence`,
  `isar_fragment_unique_normal_forms`). That anchors term-level identity ("same normal form on
  every substrate"), not the address model.

So the identity side is `CapAddress` as a **shape** (whitepaper prose + plex-core), with
confluence as the term-level anchor. Neither is a proof about addresses.

**Correspondence: `CapAddress` variants and Koru surfaces** (D; the phantom surfaces named are V):

| `CapAddress` variant (ch.06) | koru-os reading | phantom / store surface | realization A | realization B |
|---|---|---|---|---|
| `Port { scheme, identifier }` | the foreign side of a correspondence row (scheme + namespace + NID, §3.2) | row in `std/store`; `ref(T)` (KORU161) | resolution tables §3.5 (D) | `PlexGuestBoot` as a one-row contract (V) |
| `Capability { cap_id }` | a rung-1 handle `(row, slot, epoch)` minted by the resolver (§8.4), **not** a string | `unikraft/store` `<held!>`; `koruos/silo` handles (DS0, V) | DS0 refusal harness (M) | none (capabilities are strings in plex-core, no revoke) |
| `Snapshot { epoch, proof_hash }` | a frozen, content-addressed region (§6.4); `proof_hash` is artifact identity, `epoch` a generation | vmem `freeze` (one-way, V) | vmem lift (V) | none |
| `Ring { ring_id, offset }` | a live binding to a mutable shared ring: the counted, epoch-checked side (§8.5, Q2) | `std/channel` custody / transit (V) | none yet | none (no rings in plex-os) |
| `Tensor { field_name, node_id }` | associative rung B (§9): later, clear-text first | none | none | none |

**An unbound NID fails loudly.** `resolve` returning nothing is the refusal hook (§3.4). *Measured 2026-10-19 (`koruos/nid`, N3/N4): an unbound NID is refused by the layer with the fixed shape, and `create` over an existing row is refused rather than overwritten.*
`bind` must never silently overwrite an existing binding, as plex-core's `bind_address` does
today (`notes/plex-os-study.md` §3).

**Honesty notes:**

- **ch.06:** the front matter says `lean4_file: Kernel.lean`, `lean4_status: verified` for
  "SASOS = DirectMemoryDescriptor × UPageRing × CapAddress". That status is **aspirational**:
  the Lean file proves confluence, not SASOS.
- **ch.08:** the front matter says `TensorSemantics.lean`, `verified` for the holographic carrier
  and the "inverse complexity law". The law is an assertion, and the earlier study found the
  Lean file named does not back it.
- **Ch.08 is not the counting wall.** Holographic memory is about associative lookup, not about
  N holders of one region. It belongs to §9 (rung B, after clear text). The counting wall is
  answered in §8.5.
- **"Sub-50 ns inter-process messaging" and the 64-byte cache-line alignment benefit (ch.06 §3)
  are C claims with no receipts.** `UPageFrame` really is `align(64)` (V), but the ring's
  `try_push` takes `&mut self` and is wrapped in a `Mutex`. Nothing has been measured.
- **ch.07 (routing)** has nothing on revocation or sharing semantics (study §5). Its confluence
  reading only supports the half-answer already in §6.4: immutable data can be duplicated
  safely.

## 9. Associative memory: a clear-text model first, tensors later

### 9.1 What ch.08 claims (C) and what exists (V)

Ch.08 claims, without measurement:

- **Carrier:** a holographic associative carrier `U(i, s, a, r)` (identity, state, axis,
  rank).
- **Inverse complexity law:** `Steps ∝ 1/Density(U)`, so lookups get faster as memory
  fills.
- **O(1):** "O(1) parallel SIMD/GPU" tensor contraction.
- **Interference:** "constructive invariant interference" reinforces normal forms.
- **Lean status:** the frontmatter says `lean4_status: verified` against
  `isar-proofs/src/ISAR/TensorSemantics.lean`.

What exists:

- **The proof file does not prove the claim** (V, isar-proofs @ `b9534379`).
  - `TensorSemantics.lean` defines `abbrev TensorSpace := ITerm`. It proves extensional
    equality, combinator β-laws and denotational soundness for SKI/λ terms.
  - It contains no density, complexity or interference statement. A grep for
    density/inverse/holograph over all `.lean` files finds nothing relevant.
  - The "verified" status in the frontmatter is unsupported for the ch.08 theorem.
- **The plex code is a clear-text relation** (V, plex-core `kernel.rs`).
  - `SparseUTable` is a `Vec<UEntry{i, s, a, r}>`. `join(i)` is a linear filter, O(N).
    `contract` is a nested-loop relational join on `left.a == right.s`, O(N·M).
  - The CUDA backend's `contract_tensors` calls the CPU `contract`.
  - There is no superposition, no interference and no density measure.
- **Existing measurements:** no benchmark of the law exists in either repo.

### 9.2 Design

- **Rung A (required): a clear-text model.**
  - **Data:** an inspectable relation of 4-tuples `(i, s, a, r)` in `std/store`, with
    explicit indexes. The operations are insert, retract, `join(i)`, `contract(L, R)` on
    `L.a = R.s`, and exact-key associative lookup.
  - **Semantics:** set semantics, defined in prose plus a reference implementation.
    Complexity is stated per operation, for example O(1) expected hashed lookup and
    index-nested-loop contraction.
  - This is the oracle.
- **Rung B (optional, later): a tensor or associative-contraction representation.**
  - Examples: dense or sparse tensors, SIMD/GPU contraction, vector-symbolic or
    holographic reduced representations.
  - It is admitted per workload, only where it pays off, and only behind an **oracle
    gate**: differential testing against rung A on recorded and randomized workloads.
  - Exact representations must agree exactly. Approximate (superposition)
    representations must declare their error semantics, and the gate checks results
    against those bounds.
- **No inherited claims.** The inverse-complexity law, O(1) contraction and interference
  effects are hypotheses until measured against rung A at stated densities and sizes (M).

---

## 10. Requirements

Each requirement is testable and names its source. "Phase" refers to §3.4.

| id | requirement | test | source |
|---|---|---|---|
| R-ID-1 | Interface, artifact and evidence identities are distinct fields; none is derived from another | schema check: a row with an artifact hash in place of an interface id is rejected | §3.1; transcript |
| R-ID-2 | An incompatible interface change creates a new interface identity; the old row is retained and marked occluded | change a branch set and observe two rows with lineage `evolve` | membrane lineage verbs (DISCIPLINE.md §1) |
| R-ROW-1 | Correspondence rows are stored in `std/store` with `ref(T)` handles, not in `std/foreign` | a `std/foreign` entry carrying row substance is refused (existing `KORU173` behaviour) | `foreign.kz` ruling 2026-09-04 (V) |
| R-ROW-2 | Equality between two foreign names exists only as an asserted row with provenance | resolve `a ~ b` without a row and get `not_found`, not a match | KoruFlow §5 |
| R-RES-1 | Reference resolution has exactly three outcomes: found, ambiguous(candidates), not_found(ref), as typed branches | a fixture with two prefix matches returns `ambiguous` with both candidates | KoruFlow §Reference resolution; plexd `resolve_record_id` (read) |
| R-REF-1 | No dishonest fallback: an unsupported interface, relation or provider yields an explicit refusal, never a substitute | request an interface absent on the selected platform arm; build stops with a refusal naming interface, platform arm and phase | KoruFlow law 6; config.zig "module not found" (V) |
| R-REF-2 | Refusal happens at the earliest phase with the information (import, compile, configure, link, run) | each phase has at least one negative test | §3.4 |
| R-LINK-1 | An unshimmed or unbound foreign symbol is a link-time refusal, not a runtime `-1` | link a program calling an unbound libc symbol on the plex-os platform arm and see a link error | plex-os `libc_shim` (Task 1) |
| R-BIND-1 | Every live binding carries a generation; a stale generation is refused at use | restart a provider; an old binding returns `stale`, not a call into the new instance | §3.3 |
| R-CFG-1 | The Unikraft Kconfig is derived from the program's obligation set; hand-written deltas remain possible but are reported as overrides | slice §11 | BUILD.md Known-not-done (V) |
| R-CFG-2 | Every Kconfig option the build requests is checked against the resolved configuration; a silently ignored option is a refusal | set `LIBUKBOOT_INITSCHED=n`; the build either honours it or refuses | BUILD.md: INITSCHED/SCHEDCOOP silently ignored (V) |
| R-COST-1 | Resolution emits `resource -> mechanism -> cost` including image bytes per provider, RAM floor and stack demand | compare the emitted table to measured image size within a stated tolerance | §3.5 |
| R-STACK-1 | Boot stack size is computed from the maximum stack demand of reachable code (for example the 65,536 B print buffer), not injected as a constant | remove `print`; required page order drops below 6 | BUILD.md / unikraft README (V) |
| R-BUDGET-1 | Budget exhaustion is a normal outcome branch, not a crash | flow with budget 1 and cost 2 returns `budget_exhausted` | KoruFlow law 3; plex-net `execute_flow` (read) |
| R-OBL-1 | The runtime enforces the same obligation signature the compiler checks | a runtime-dispatched flow that skips a discharge is refused | KoruFlow law 4 |
| R-CAP-1 | Cross-boundary authority is an attenuated, signed, expiring capability; audience, verb and scope mismatches are explicit refusals | port plex-net escalation tests | plex-net `UCANLease` (read; tests passed, M) |
| R-REVOKE-1 | Mutable shared regions are guarded by a store-held count and epoch; a stale epoch is refused | revoke, then use the old binding, and get `revoked` | §6.4 (D) |
| R-MEM-1 | Reserving address space costs metadata proportional to the number of regions, not their size | reserve 1 GiB and 4 KiB; compare metadata growth | vmem (V) |
| R-SESS-1 | Sessions own jobs; views attach and detach explicitly; attaching to an unknown session is `not_found` | §11 view test | plexd gap (read); `std/bridge` (V) |
| R-SESS-2 | With all views detached, jobs continue; a new view observes the same state | §11 view test | transcript; decision 002 |
| R-SUP-1 | Supervised services expose an observable snapshot (up, instance, restarts, last outcome); the supervised child, not the supervisor, owns external endpoints | snapshot fields present after a forced crash | plexd keepalive (read); `std/supervisor` semantics (V) |
| R-WRITE-1 | Agent-originated writes enter a staging area; only a principal with promote authority binds them; promote is one-shot | double promote is refused | plexd quarantine (read) |
| R-RUNG-1 | Each platform arm declares its highest enforceable rung; each row declares the lowest rung its provider needs; a mismatch is a configure-phase refusal | bind a rung-2 row on the Unikraft rung-0 platform arm and see the refusal | §8.4 |
| R-TCB-1 | Every unchecked foreign provider (`proc` host body, C library, syscall) is listed in the image's TCB manifest with evidence, or is behind a silo boundary; an unlisted one is refused | add an unlisted C provider and see the build refuse | §8.4 FFI rule |
| R-HANDLE-1 | A live binding is obtainable only from the resolver's mint; Koru code cannot construct one | a negative test constructing a handle without the mint fails to compile | §8.4; matrix `unauthorable` |
| R-HANDLE-2 | A handle carries interface identity, authority set and epoch; a name hash alone grants nothing | call with a valid NID but no handle and get `denied` | §8.4 (contrast with PS NIDs) |
| R-TOK-1 | Cross-image tokens carry a delegation chain (parent reference); attenuation only narrows; revoking a parent invalidates all descendants | port plex-net escalation tests and add parent-revocation tests | §8.2 (chain missing in plex) |
| R-TOK-2 | Signed token payloads use an unambiguous canonical encoding (length-prefixed or a canonical serialization), not delimiter-joined strings | two tokens differing only in field boundaries produce different signatures | §8.2 (mesh.rs `:`-join) |
| R-REV-1 | Every authority is time-bounded by a lease, and revocable by epoch through a store-held slot | revoke, then use, gives `revoked`; expire, then use, gives `expired` | §8.5 |
| R-REV-2 | A revoked mutable region is reused only after a quiescence point proves no holder can still access it | stress test with a concurrent holder during revoke and reuse | §8.5 |
| R-SILO-1 | Silo rollback restores the content of a frozen baseline snapshot (content hash equal), not metadata | mutate, roll back, compare hashes | §8.2 (plex rollback is metadata only) |
| R-SILO-2 | A silo update commits only when the health-probe obligation is discharged with `ok`; otherwise the previous snapshot stays live | inject a failing probe; old snapshot keeps serving | thesis §6.2 (C); plex `update_silo` (V) |
| R-SILO-3 | Every call into a silo crosses a gate that checks a rung-1 handle; grants into a silo are attenuated and recorded | call without a handle gives `denied`; the grant log lists the grant | §8.4 |
| R-HW-1 | Rung-2′ and rung-3 claims are made only with measured evidence on the stated hardware or emulator (M) | evidence class check on the platform-arm row | §8.4 |
| R-ASSOC-1 | Associative memory has a clear-text reference model (4-tuple relation with insert, retract, join, contract and lookup) with specified semantics and per-operation complexity | reference tests | §9.2 |
| R-ASSOC-2 | A tensor or holographic representation is admitted only behind an oracle gate: exact equality with the clear-text model, or declared error bounds for approximate ones | differential test suite on recorded and randomized workloads | §9.2 |
| R-ASSOC-3 | Performance claims for any rung-B representation are measured against rung A at stated sizes and densities; the inverse-complexity law is not assumed | benchmark report with evidence class M | §9.1 |
| R-DOD-1 | DoD is met only when DoD-1..4 pass their acceptance tests (§0.4 M2, M5, M9, M10) in QEMU on the box on an L2/L3 arm, with evidence filed. L1 runs are oracle evidence and never count | evidence directory holds serial logs and screendumps per milestone | §0, Fabian |
| R-DOD-2 | Every Linux-ABI identity the DoD workloads use is a correspondence row, bound or refused loudly; no silent `ENOSYS` | refusal log lists identity, caller and milestone; a run with an unlisted `ENOSYS` fails | §0.1, Appendix C |
| R-DOD-3 | Each milestone's row set is derived from an L1 `strace -f` trace of the same workload, filed beside the test | trace file present and diffed against the arm's shim log | §0.1 |
| R-DOD-4 | DoD-1 oracle is an independent FS checker on the host (`e2fsck -fn` or `fsck.fat -n`), not koru-os code | M2 test invokes the host checker | §0.3 |
| R-DOD-5 | T-CYB (cyberboot) stays green from M4 onward on every arm that claims DoD-2 | regression run per arm | §0.2 |
| R-EVID-1 | Every row and every published number carries its evidence class (V/M/C/D) | lint: a row without evidence is rejected | this note |

---

## 11. First vertical slice

Goal: one program, one platform arm (Unikraft), demonstrating all three parts of the
contract.

### 11.0 The realization graph, and what the slice is for

*Folded in 2026-10-19 about 18:35 CEST from Fabian's second paste (authoritative guidance; the wording here is this note's).*

**The first architectural object is the realization graph**: the graph built at build, load and
service-connection time that connects a Koru program, the store (rows, evidence) and a target
realization. Every build output explains three things, the three tables of §3.5:

- interface → provider → binding;
- resource → mechanism → cost;
- missing → refusal.

The shell **manages realized apps**; it does not define their identity. KolibriOS is a **donor**
(§4.1), not a prerequisite.

**What already crosses the boot boundary (C, `koru/examples/unikraft/BUILD.md`; S5 reproduces it):**

- Koru emits a freestanding archive with a C-ABI seam, booting at 164,544 B with a 2 MB RAM floor,
  with no syscall shim and no VFS;
- the ELF-loader route (app-elfloader, M3–M9 here) keeps the Linux ABI.

The slice does not need a bootloader or a wholesale port first.

### 11.1 Obligation-derived Unikraft configuration

**Input.** A Koru program that prints, opens a 9P mount, and runs one cooperative job.

**Steps:**

1. Collect the program's required interfaces from its imports and discharged
   obligations. For example:
   - `std/io:print` needs a console and stack demand;
   - `unikraft/ninep` needs `LIBUK9P`, a virtio-9p transport and `LIBVFSCORE` (H: exact
     options to be read from the ninep lift);
   - no `unikraft/sched` import means no scheduler.
2. Map each interface to Unikraft providers through rows (`interface -> CONFIG_* set`),
   with evidence.
3. Generate `Kraftfile` and `Makefile.uk` through the existing `unikraft:image` and
   `unikraft:kconfig` emitters, extended so the Kconfig is computed. Hand blocks remain
   as reported overrides.
4. After `kraft build`, read the resolved `.config` and the image's section table, then
   emit the three tables of §3.5.

**Success criteria:**

- **S1.** The generated configuration boots the program under QEMU, with output
  identical to the hand-configured build.
- **S2.** A program that imports no scheduler yields an image with no `uksched` or
  `ukschedcoop` objects. If Unikraft forces them in, the build refuses and names the
  forcing dependency. A silently retained 99 KB is the failure this slice exists to
  remove.
- **S3.** The `.eh_frame` share is reported in the cost table. Removal through a
  linker-script `/DISCARD/` is attempted; if the image no longer boots, the result is
  recorded as M with the reason.
- **S4.** The stack page order is computed from reachable stack demand (R-STACK-1) and
  printed with its derivation.
- **S5.** Image size and RAM floor are measured on the box and recorded as M. The
  164,544 B / 2 MB baseline is C until reproduced.

**Result, 2026-10-19 19:00–19:05 CEST (M, TCG; `experiments/realize/`, checks frozen in
`c2f4de7` before the counted runs).** The comptime command `koruc <boot.k> realize gen`
(`koru/realize/index.kz`, koru-libs shape) walks the program's flows, collects every used
`module:tor`, maps each through a row table (interface → kconfig + stack demand + resources,
with evidence) and writes `Kraftfile`, `Makefile.uk` and `realize.txt` (the three tables of
§3.5). An interface with no row, or an author line that contradicts a derived line, is a
`refused:` line with no Kraftfile written. The input was Slice A and DS0 (print plus the
`koruos/slice` or `koruos/silo` lift; no 9P program yet). Per criterion:

- **S1: met.** Both derived images pass their frozen checks 3/3 (Slice A S9–S14 and x; DS0
  `expected.txt`), with the allocator lines now derived rather than author-written.
- **S2: met, but the 99 KB is not reproduced.** No program imports a scheduler, so realize
  picks `CONFIG_LIBUKBOOT_INITNOSCHED=y` and `CONFIG_LIBUKSCHEDCOOP=n`. Both hold in the
  resolved `.config`, and the image has 0 `uk_sched_*`, `*schedcoop*` and `uk_thread_*`
  symbols (the pinned builds have 20). BUILD.md's "silently ignored `'n'`" comes from the
  `INITSCHED` choice selecting the scheduler; choosing `INITNOSCHED` removes it. The saving
  is 4,304 B of file and about 4.7 KB of `.text` per image, not 99 KB, because
  `OPTIMIZE_DEADELIM` already drops most of the unreferenced scheduler code. The 99 KB
  stays C for builds without dead-code elimination.
- **S3: not done.** The `.eh_frame` cost and the `/DISCARD/` attempt are still owed.
- **S4: partly met.** The order is computed from declared row demands
  (runtime 16 KiB + print 64 KiB + lift 4 KiB, + 25 %), so it comes out as **order 5 (128 KiB)**
  instead of the pinned 6. It is then checked against a measured static bound,
  `stack-demand.py`. That bound follows direct edges from `ukplat_entry2` (the first function
  on the boot stack, which `plat/kvm/x86/setup.c` sizes with `__STACK_SIZE`), counts every
  push and the largest `sub rsp`, and charges each indirect call the largest demand of any
  address-taken function. It gives 76,544 B (Slice A) and 74,216 B (DS0), and both fit. In
  Slice A, `koru_main` holds 72,024 B of that, with the print buffer inlined. The order-4
  probe (64 KiB, not counted) is refused by the bound, and booting it anyway crashes at
  0.10 s (`rip 0`). The order is not yet derived *from* the measured bound; the rows declare
  and the bound verifies.
- **S5: image size measured, RAM floor not.** Slice A: 197,504 → 193,200 B. DS0:
  181,120 → 176,816 B (`experiments/realize/evidence/sizes.txt`). The RAM floor is still owed.
- **Refusals (R6):** an unrowed lift and a contradicting author line are both refused with
  no Kraftfile written, and the control is accepted.

### 11.2 One binding refusal

The same program is built with `unikraft/ninep` imported but no 9P transport row for
the selected platform (for example a platform without virtio).

- **S6.** The build stops at the configure phase with a refusal naming:
  - the interface (`ninep.transport`)
  - the platform arm (`unikraft/<plat>`)
  - the phase
  - the missing row

  No image is produced. The refusal is covered by a negative test.

### 11.3 One detachable view

A session host on the hosted platform arm, built on `std/bridge` runs one job that appends a line to a
9P-exported (or plain) file every second. Two views attach: a TUI and a read-only HTTP
or 9P reader.

- **S7.** Detach both views for 30 s, then attach a new view: the job's lines produced
  meanwhile are present. The session id is unchanged.
- **S8.** `attach` with an unknown session id returns `not_found` and creates nothing.

### 11.4 Slice A: a discussion-worthy prototype (D, not frozen)

The smallest prototype that exercises the whole contract end to end:

- **The program.** A headless task, plus bounded storage, plus a clock/event source, plus a
  terminal status view.
- **The steps:**
  - **S9.** The Koru app declares a **versioned interface import** (e.g. `store.bounded@1`,
    `clock.tick@1`).
  - **S10.** The loader selects an **authorized** provider from the manifest (§3.0, §3.6).
  - **S11.** The loader **rejects** an incompatible provider. A manifest that offers only a
    provider with the wrong descriptor or contract revision is refused before execution, with
    the fixed shape (§3.4).
  - **S12.** A real operation runs through the selected provider: a bounded write and a read
    back; a tick drives the task.
  - **S13.** A supervisor tracks the task's resources and lifecycle (the Spawn child record,
    §8.6.2: identity, bag, reap obligation).
  - **S14.** The terminal status view **disconnects and reconnects** without terminating the
    task. The reconnected view shows the state produced meanwhile (§7 operational test; it
    extends S7/S8 to the target realization).
- **Order.** S9–S14 are acceptance candidates, to be frozen before any counted run as usual.
  Slice A can run on the Unikraft arm natively (no Linux ABI) and reuses 11.1–11.3.

**Slice A result (2026-10-19, M under TCG).** S9–S14 were frozen at 18:46 CEST
(`experiments/slice-a/ACCEPTANCE.md`, commit `88516f4`). The counted runs at 18:48 CEST pass
**3 of 3**, along with the compile gates and the DS0 regression.

- **Realization.** The lift is `koru/slice` (module `koruos/slice`), in koru-libs shape. Its
  supervisor is a Spawn stand-in that matches §8.6.2: child record, grants that take custody of
  bindings, seal, start on evidence, wait, reap, abandon.
- **The view.** The status view runs over `isa-debugcon`. A host renderer detached for 3.5 s
  while the task advanced 13 ticks. The first frame after the reattach reconstructed the gap
  from the bounded store.
- **Not claimed:**
  - the child runs on the supervisor's thread (rung 0, one address space);
  - artifact identity hashes the source block, not the linked bytes;
  - authorization is an allowlist, not a signature;
  - the guest cannot see attach and detach.

Evidence: `experiments/slice-a/evidence/`.

**Only after Slice A:**

1. a second substrate (the same app realized on another arm, with the same rows);
2. measured costs of the sparse address-space regime (§6.1a);
3. the KolibriOS donor audit (§4.1);
4. native boot, once the contract is worth booting.

### 11.5 Post-concordance work list (ordered)

*Recorded 2026-10-19 about 18:40 CEST from Fabian's whitepaper analysis (ch.06/08 of `Cypoe/plex-shell` @ `f34e473f`, now readable through GitHub). Decisions are Fabian's, or a synthesis he endorsed by pasting it; the wording here is this note's.*

1. Concordance registration (§2.3): every koru-os term cited or added.
2. Obligation-derived kconfig (§11.1). *2026-10-19 19:05: S1, S2 and R6 met, S4 partly, S3 and the RAM floor owed (§11.1 result).*
3. The NID binding layer: rows, admission and refusal (§3.2–§3.6, §11.2, Slice A S9–S11). *2026-10-19 19:16: `koruos/nid` N1–N10 3/3 PASS under TCG, regressions 3/3 (§11.6); 19:27: build-time refusal of required imports via realize table 3, L1–L4 PASS (§11.7).* *19:37: the Spawn skeleton `koruos/spawn` S1–S11 3/3 (§8.6.7a) is a first piece of the runtime-supervisor cross-cutting item.*
4. **SASOS ascent** over one address space (§6.1a), with the **counting wall as a measured
   spike** inside it. The design is closed (§8.5); the measurement is the work.
5. Protection bits.
6. `page_set_attr` and thaw. vmem `freeze` is one-way today, so thaw is new and must follow
   evolve-don't-mutate.
7. Stack VMAs.
8. Concurrency and SMP. Today everything is single-core `ukschedcoop`.
9. A 9P headless shell (§7, `unikraft/ninep`).
10. Generalizing the manifest: from the Kraftfile to the realization graph (§11.0).
11. The KolibriOS donor audit (§4.1).

**Cross-cutting:**

- protection domains over one VAS (rung 2, §8.4);
- a runtime supervisor matching `std/supervisor` semantics (§2.2: today a compile-time retry
  fold with no runtime object; Q38);
- provenance for shared regions (who granted, under which epoch; §8.6.2 grants).

**Relation to Slice A and M9.** Items 1–3 are Slice A's prerequisites, and Slice A sits inside
them. Spawn's supervisor (§8.6) is the runtime-supervisor item. The order of Slice A vs M9 is
still Q37, and Q30 is untouched.

**Out of scope for the slice:**

- the microkernel platform arm
- counting and revocation (§6.4)
- KolibriOS translation
- plex-os platform arm rows beyond `PlexGuestBoot` as a documented row


### 11.6 The NID binding layer (result, 2026-10-19 19:13–19:17 CEST, M under TCG)

`koru/nid/index.kz` (`koruos/nid`, koru-libs shape) makes the binding chain of §3.0
executable:

```
foreign import (scheme/ns/version/name) --NID--> correspondence row --> canonical interface (name@rev) --> provider export (artifact:symbol, linked here)
```

**Rows** are asserted in a manifest; equality between foreign names is never inferred
(§3.2). In the test, `c/libc/1/fputs` and `linux/x86_64/1/write` are two rows onto one
`koruos.console.write@1`. A row is admitted only if its export is linked into this image
**and** declares that it realizes exactly that revision, a reduced §3.6 descriptor check.

**The verbs:**

- `open`: mints the table;
- `resolve`: mints a `*Binding<live!>`, or refuses with `phase=link`, `missing=correspondence
  row` and the offered near misses;
- `call`: goes through the binding; refused `stale` if the generation moved;
- `retarget`: re-points an interface's rows to another export with NIDs unchanged, bumping
  the generation (the AnyPS5/shadPS4 precedent);
- `release` and `close`: `close` prints table 1 and the refusal count.

`create` on a bound foreign name is refused. `evolve` occludes its parent row and keeps it.

**Result:**

- N1–N10 and R hold 3/3 on one image (`ecdecd9d…`, 209,584 B; `experiments/nid/README.md`).
  The host recomputes all 35 printed ids independently.
- Regressions: Slice A and DS0, 3/3 each.
- The kconfig is derived by `koruos/realize`, which gained the `koruos.nid` row.

**Findings:**

- **Auto-discharge order.** koruc auto-discharges a never-released binding (B5 rule) but
  emits the `release` **after** the explicit `close`. `close` therefore detects
  `outstanding=1` and keeps the table instead of freeing it under the binding. That is a
  runtime guard against an ordering the phantom checker does not see; the lift has to carry
  it.
- **Stack bound.** The conservative bound (87,592 B) exceeds the rows' declared sum
  (86,016 B) by 1.5 KB, entirely through the charge for indirect calls. It stays inside the
  25 % margin and the derived 128 KiB. The direct-edge demand is 76,368 B.
- **Narrow descriptor.** Of §3.6, only the interface revision is checked. Layout, effects and
  authority are Slice A's `resolve` (S9–S11) and are not yet joined to NID rows.

**Not yet:**

- rows in `std/store` with `ref(T)` (they live in a fixed array here);
- artifact hashes on exports (Slice A has them; this lift names artifacts only);
- signed rows (Q3 item 4);
- the cross-image handle of §8.4;
- ~~the link phase proper~~: done in §11.7.


### 11.7 Build-time resolution: required imports refused before an image exists (result, 2026-10-19 19:23–19:27 CEST, M under TCG)

This closes the configure and link rows of §3.4 for `koruos/nid` programs. `koruos/realize`
now evaluates the binding chain during `koruc <boot.k> realize gen`:

- the export table is read from the `koruos/nid` module's host lines, the same lines that
  are compiled into the image;
- literal `open` manifests are admitted with the lift's rules;
- literal `resolve`/`probe` are looked up in the lexically enclosing table, and a literal
  `retarget` is applied on its `ok` arm.

The lift distinguishes two lookups:

- **`resolve` is a required import** (§3.0: "each required interface resolves to …"). If it
  cannot bind, it becomes a table-3 refusal with `phase=configure`, no Kraftfile is written,
  and so no image exists (§3.5).
- **`probe` is an optional lookup.** It is only predicted; its run-time refusal is a branch
  the program handles.

**Result** (`experiments/nid-link/`, checks frozen in `5ad7948`):

- **L1, agreement:** the 16 build-time predictions equal the image's 16 run-time outcomes
  in order and field for field, 3/3.
- **L2, refusals:** four required-import refusals before any image: no row, another
  version, a refused table, a 4-bit NID collision. The controls are accepted.
- **L3:** N1–N10 still hold 3/3.
- **L4:** Slice A and DS0 regressions 3/3.

**Limits:**

- Literals only; a non-literal required name is refused at build time ("use probe").
- Table scope is lexical.
- The admission rules exist twice (lift and realize), and L1 measures that the two agree.
  Sharing one implementation waits on Q33.
- Generations and staleness stay run-time facts.

---

## 12. Open questions

1. **Counting wall.** *Closed at the design level (D), 2026-10-19 about 18:40 CEST by Fabian
   ("Zähl Mauer wir hier schon beantwortet haben"): the answer is §8.5.*
   - Revocation is by indirection: an epoch per store-held slot, plus leases. There is no
     counting of holders.
   - The count lives in the store, not in a counted phantom form. Reclamation is epoch plus
     quiescence, and frozen regions need neither.
   - **Still owed (M):** measure it against the three specimens (refcount, CR3 singleton,
     sibling fids), including the compile-time vs run-time cost. This is a spike inside the
     SASOS ascent (§11.5). It is not a new design question.
2. **Snapshot sharing.** Can every shared-read case be expressed as a frozen,
   content-addressed region, so that counting is needed only for mutation? What breaks
   (DMA buffers, rings)? *(Still open: this is the one gap §8.5 does not settle. A DMA buffer
   or ring is mutable and shared, so it falls under the counted, epoch-checked side, and its
   reclamation grace period with a device as holder is unmeasured.)*
3. **NID derivation.** *Answered by work, 2026-10-19 (M, `experiments/nid/`); Fabian may
   overrule:* a hash, two of them. The foreign NID is the first 8 bytes of
   `sha256("koruos.nid.v1|" + scheme/ns/version/name)` and the interface id the same over
   `"koruos.iid.v1|" + name@rev`, both shown as 11 base64url characters. Collisions are
   refused at open and at resolve (N6). Authority is not in the hash: only a minted binding
   grants a call (§8.4). Still open: who signs rows (item 4).
   - Does koru-os adopt a hash of the minted interface name and contract revision, or
     an opaque id assigned at mint?
   - The PS4 salted SHA-1 truncation is a precedent, not a requirement.
   - Collision handling must be an explicit refusal either way.
4. **Where rows are authored.** Generated by `std/runtime` scope collection, hand-written
   per platform arm, or both? Who signs evidence?
5. **Kconfig completeness.** Can Unikraft's resolved `.config` always be compared with
   the request (R-CFG-2), or do some options have no observable effect?
6. **Microkernel platform arm.** Which kernel (seL4, a minimal L4) gives the cheapest
   endpoint-per-row binding without reintroducing the timesharing barrier?
7. **Licence.** The koru README says MIT, but there is no LICENSE file and GitHub reports
   none. This should be confirmed before any decision about GPL-2.0 KolibriOS reuse or
   wrapping.
8. **Revocation in KoruFlow.** The KoruFlow doc lists "how capability revocation and
   dynamic scope updates are represented" as open. koru-os should answer it once, for
   both.
9. **Rung-1 handle representation in one image.** A slot index plus generation in a
   store table, or a pointer with a side table? What does the check cost per call, and
   can the compiler elide it where obligations already prove liveness?
10. **Rung 2 on Unikraft.** What does a gate (trampoline plus CR3 switch plus handle
    check) cost? The repo measures 256M vs 64M for a deep page-table clone; is a shallow
    or shared-kernel-half clone admissible without weakening the active-table rule?
11. **MPK/PKU (rung 2′).** Is it worth supporting, given that it needs binary inspection
    of untrusted code for `WRPKRU`?
12. **CHERI (rung 3).** What is the state of Zig and LLVM purecap support for Morello or
    CHERIoT, and can Koru emit through it? Is QEMU-CHERI enough for M evidence, or is a
    Morello board needed?
13. **TCB manifest granularity.** Is the TCB listed per `proc`, per foreign library or
    per image? Who signs it, and how does it interact with the membrane's evidence
    events?
14. **Silo substrate on Unikraft.** A protection domain inside one image, or a separate
    unikernel instance talking over virtio/9P? Each changes what rollback can restore.
15. **Associative rung B.** Is there a workload where a tensor representation beats an
    indexed clear-text relation by a measured margin? If none is found, rung B stays
    unbuilt.

16. **Unikraft FS and graphics coverage.** Does an ext2/ext4 or FAT driver exist for
    Unikraft `vfscore` (for example an lwext4 port), and does any virtio-gpu, DRM or
    evdev work exist? None was found; this was not exhaustively searched.
17. **Does L1 count?** *Closed (Fabian, DRAFT 5):* no. L1 is oracle and trace
    source only. Linux may appear only as a driver personality in a driver silo (§0.6).
18. **`ascii-animator`.** *Partly resolved (Fabian, DRAFT 5):* cyberboot = `Cypoe/boot-animator`
    (`d1e5d49b`). That pushed state is old and lacks the demo `.anim` files and
    `/bin/ascii-animator`. T-CYB runs with a labelled stand-in (plex-os `boot.anim` plus
    the plex-libs `anim.rs` player). Still open: push the newer boot-animator state, then
    switch T-CYB to it.
19. **`fork` on Unikraft.** Does `posix-process` provide `fork` semantics good enough
    for busybox `ash`, or only `vfork`/`clone`? If only the latter, is a spawn-only
    shell acceptable for DoD-2?
    *Answered in part (V, M3–M5a): posix-process gives `vfork` and `clone` with `CLONE_VM` plus
    `execve`, and no `fork` (B20).* **Direction ruled 2026-10-19 about 18:20 CEST by Fabian:** no
    wholesale POSIX fork. The process model is Spawn (§8.6), a dissected fork with explicit rights
    bags. `vfork`/`execve` stay only as a thin, loud compatibility layer under it (§8.6.4). Still
    open for Fabian: hush (NOMMU/vfork) is the DoD-2 shell in M5a. Does "spawn-only shell"
    settle DoD-2, given that `ash` with `fork` is no longer a goal?
    ***Closed 2026-10-19 by Fabian:*** *DoD-2 is reformulated only after the Spawn lib has passed
    its acceptance, not now. Until then the DoD-2 wording (§0) and the M5 row stay as written,
    M5 stays open on its `fork` clause, and no milestone counts a spawn-only shell as DoD-2.
    The reformulation is a task for the Spawn-lib acceptance (§8.6, Q30).*
20. **QML required?** *Closed (Fabian, DRAFT 5):* QML is one example. It is the
    canonical exemplar for DoD-4; HTML fragments and components are separate tracks.
    Note: the Hyprland compositor itself needs no Qt, and noctalia v5 dropped
    quickshell (§0.3).
21. **LKL as a binding source.** *Closed (Fabian, DRAFT 5):* accepted, inside the
    slim driver-silo model only (§0.6, R-SILO-1..5).
22. **Box resources.** *Updated 2026-10-18 ~19:37 CEST.* `/dev/kvm` is now
    `crw-rw-rw-`, but creating a vCPU oopses the box kernel (`kvm_spurious_fault` in
    `vmx_vcpu_create`, 6.12.94+). The same oops was already in the log before this
    work. QEMU with `-accel kvm` produces no output, so KVM is unusable and all
    measurements are TCG. Who can fix nested VMX on the box host?
23. **`agents-design` integration.** Fabian's `agents-design` exists only as prose on his
    PC and is not available here. When it is, how does it shape the Koru-native
    declarative-UI track and the QML exemplar? This is an open item, not a DoD gate.
24. **fasmg community packages.** Where do the KolibriOS community fasmg packages and the
    fasm platform modules Fabian mentions live? Nothing named `fasmg` is in
    `KolibriOS/kolibrios` @ `69df0061`. *(Lower priority since 2026-10-19 about 18:40: a FASM
    dialect is ruled out (§4.1). The packages matter only as donor or behaviour reference.)*
25. **LKL on Unikraft.** Can LKL's host operations be bound to Unikraft scheduling,
    allocation and timers? How does a silo get PCI/MMIO, IRQ and DMA access for
    `virtio_gpu`/`virtio_input`/`virtio_blk`, and is `intel-iommu` in QEMU needed to
    confine DMA?
26. **GPL-2.0 boundary.** Do LKL and KolibriOS drivers in a separate silo, loaded at run
    time and spoken to only through rows, keep the koru-os image outside GPL-2.0
    obligations? This needs a legal answer, not an engineering one. It is coupled to
    the koru licence itself (README says MIT; no LICENSE file).
27. **KolibriOS DRM snapshot.** Which Linux version does `drivers/video/drm` track,
    and does `vmwgfx` there drive QEMU's `vmware-svga` today?
28. **Native KMS provider and DoD-3.** M6 binds `kms.*` to a native koru-os
    `bochs-display` provider (§0.4 "M6 decision"). Does DoD-3 accept a native koru driver
    for the GPU, or must the display path go through a driver silo (DS3) for DoD-3 to count?
    Since M7 the same question covers input: the `input.*` rows are bound to a native i8042
    PS/2 keyboard provider (§0.4 "M7 decision"), not to DS4.
    **Closed 2026-10-19 15:55 CEST by Fabian: "Native erst, Silo-Variante als eigener
    Meilenstein danach."** DoD-3 (M9) counts with the native `bochs-display` (KMS) and i8042
    (input) providers. The silo variant (DS3 for the GPU, DS4 for input) becomes a milestone of
    its own after M9; it is not a DoD-3 requirement.
29. **M9 (h2) needs Hyprland to start foot, which needs fork.** *Ruled 2026-10-19 about
    18:20 CEST by Fabian:* M9 is not passed and stays open, and (h2) is **not** amended. A Spawn
    design comes first (§8.6). (h2) is met only when the frozen trigger starts foot through Spawn
    (§8.6.5, stage 1 or 2), measured 3/3.
30. **Which Spawn stage closes M9 (h2)?** Is stage 1 enough, or must (h2) wait for stage 2?
    Stage 1 is: `posix_spawn` in the patched hyprutils/Hyprland executor and in foot, running
    through the compat layer that mints Spawn children. Stage 2 is: Hyprland holds no spawn
    authority and asks a supervisor. Related: are small patches to hyprutils, Hyprland and foot
    acceptable, given that fork-as-vfork is rejected (§8.6.5)?
31. **`posix-inherit` default in the compat layer.** Should the compat layer be POSIX-faithful
    (every non-`CLOEXEC` fd becomes a recorded grant) or listed-only (a policy row names what a
    given image's children may inherit, and the rest is dropped with a row)? The draft allows
    both and leaves the default open.
32. **app-elfloader's loader.** `unikraft/spawn` must load an image for a child. app-elfloader is
    an application, not a library, in Unikraft 0.21. May the lift carry a local split of it, or
    should spawn wait for an upstream library form?
33. **Moving the OS lifts to koru-libs.** In which order should `korumemfd`, `korupty`,
    `korusnap`, `korusysfs`, `koruinput`, `korukms` and `koruext2fs` move, and by which
    criterion? Each move is a re-lift in Koru with gates, not a copy. Pushing to
    `Cypoe/koru-libs` also needs its own authorisation; it is a different remote from
    `Cypoe/koru-os`.
34. **Ambient set and rung.** Is the ambient set right: memory within budget, the monotonic
    clock, `exit` and yield? Does Spawn on rung 0/1 count for DoD purposes as a provenance
    boundary (§8.6.2), with containment of a hostile child deferred to rung 2?
35. **Descriptor fields vs phases.** Which fields of the interface descriptor (§3.6) can
    `koruc` check at compile time, and which only at configure, link or run time? This matters
    most for reentrancy and concurrency, and for cancellation. Where does a Linux-ABI row (a
    syscall) get its descriptor from: hand-written, or derived from traces?
36. **Transactional region updates on Unikraft.** Can vmem and `unikraft/paging` apply a
    multi-step change (split, remap, protection change) atomically under the cooperative
    scheduler, or does §6.1a rule 5 need a journal or a two-phase protocol? Also: what is the
    defined failure when commit cannot be backed (§6.1a rule 6)?
37. **Slice first or M9 first?** Should the next work be Slice A (§11.4), with Spawn built
    first for its supervisor (S13), while M9 (Spawn stage 1 for Hyprland) waits? Or do both
    proceed in parallel? This is the tension noted in §0.4 ("Architectural priority vs the DoD
    ladder"). It does not answer Q30.
38. **Runtime supervisor vs `std/supervisor`.** `std/supervisor` elaborates at compile
    time into a bounded retry fold and has no runtime object (§2.2). Should the runtime
    supervisor (§11.5; Spawn's reap and detach target, §8.6) lower from the same declarations
    and keep the same semantics, or be a separate interface that only cites them?

---

## Sources

**korulang/koru @ `3d81f837`:**
- `src/config.zig`
- `examples/unikraft/BUILD.md`
- `koru_std/foreign.kz`
- `koru_std/supervisor.kz`
- `koru_std/bridge.kz`
- `koru_std/bridge.grants.kz`
- `koru_std/store.refs.kz`
- `koru_std/store.refhomeapi.kz`
- `koru_std/channel.custody.kz`
- `koru_std/channel.home.kz`
- `koru_std/rings.kz`
- `README.md`
- the full tree listing

**korulang/koru-libs @ `ff5cb559`:**
- `unikraft/README.md`
- `unikraft/index.kz`
- `unikraft/vmem/README.md`
- `unikraft/paging/README.md`
- `unikraft/ninep/README.md`
- `unikraft/store/README.md`
- `metal/package.json`
- the full tree listing

**Cypoe/koru @ `601ba53d` (branch `ccomp`):**
- `docs/concordance-matrix.md` (canonical terminology; see §2)

**Cypoe/plex-shell @ `f34e473f`:**
- `notes/plex-os-study.md`
- `notes/plex-shell-crates.md` (test run: 108 passed, 1 failed; log in `notes/evidence/plex-shell-cargo-test.log`)
- `docs/concepts/koruflow-semantic-capability-protocol.md`
- `docs/concepts/PLEXD_LOCAL_AGENT_HANDOFF.md`
- `docs/concepts/GUI_REQUIREMENTS.md`
- `docs/decisions/002-qt-niri-projection.md`
- `docs/GOAL.md`

**Other repos and local documents:**
- Cypoe/isar-proofs @ `b9534379`: `src/ISAR/Kernel.lean` and the axiom grep (see plex-os-study.md).
- KolibriOS/kolibrios @ `69df0061`: `kernel/trunk/` listing, `kernel/trunk/COPYING.TXT` (GPL-2.0).
- `/workspace/koru-distill/DISCIPLINE.md` (draft 2026-10-17, koru@24c1538).

**Background (C, not re-read for this note):**
- Strom and Yemini, "Typestate", IEEE TSE 1986.
- Chase et al., Opal (1994).
- Heiser et al., Mungi (1998).
- Organick, The Multics System (1972).
- Madhavapeddy et al., Unikernels (2013).
- Kuenzer et al., Unikraft (EuroSys 2021).
- The OTP supervision principles.
- PS4/PS5 NID scheme as documented by the shadPS4 and AnyPS5 projects.

**Added in DRAFT 3 (plex-shell @ `f34e473f`, read in full):**
- `docs/1_whitepaper/00_ABSTRACT_AND_GLOSSARY.md`
- `docs/1_whitepaper/03_CONFLUENCE_AND_PCC.md`
- `docs/1_whitepaper/06_SASOS_SUBSTRATE_KERNEL.md`
- `docs/1_whitepaper/07_CONFLUENT_METRIC_SPACE_AND_ROUTING.md`
- `docs/1_whitepaper/08_HOLOGRAPHIC_ELASTIC_MEMORY.md`
- `docs/2_architecture_manual/01..06`
- `docs/3_historical_context/02_SINGULARITY_MIDORI_DBOS.md`
- `docs/PLEXUS_UNIFIED_THESIS.md`
- `docs/WHITEPAPER_AUTOMATIC_SYSTEMS_PROGRAMMING.md`
- `docs/ARCHEOLOGY.md`
- `docs/concepts/LIVING_NETWORK_FUTAMURA_SQUARE.md`
- `docs/concepts/AUTOMATIC_SYSTEMS_PROGRAMMING.md`
- `docs/ISA_PHYSICS_MATHEMATICAL_SYNTHESIS.md`

**Code (plex-shell @ `f34e473f`):**
- `crates/plex-core/src/{unikernel.rs, multikernel.rs, kernel.rs, pcc.rs, tagged_word.rs, hardware/cuda.rs}`
- `crates/plex-net/src/mesh.rs`
- `crates/plex-desktop/src/silos/runtime.rs`

**Proofs:** isar-proofs @ `b9534379`, `src/ISAR/TensorSemantics.lean`.

**DRAFT 5 sources:**
- `Cypoe/cyberboot`: GitHub connector `scm_repo_not_accessible`; `https://github.com/Cypoe/cyberboot` 404 (2026-10-18, 19:23 CEST).
- KolibriOS/kolibrios @ `69df0061`: full git tree listing (44,701 paths): `drivers/{ethernet,usb,mouse,disk,video/drm,ddk/linux}`, `kernel/trunk/{fs,blkdev,video}`, `programs/develop/fasm/1.73`, `COPYING.TXT` (V, names only).
- lkl/linux README and commit list; SUSE Package Hub `lkl` (GPL-2.0-only, experimental); LWN 811575 (C).
- noctalia-dev/noctalia-shell README and docs.noctalia.dev (v5 native Wayland/GLES, v4 quickshell-based) (C).
- quickshell.org, `Quickshell.Hyprland` docs v0.2.0 (C).
- hyprwm/hyprland-qt-support, hyprwm/hyprland-qtutils (superseded), Hyprland issue #8850, Hyprland wiki `hyprland-guiutils` (C).
- Box: QEMU 10.0.13 device list (`vmware-svga`, `rtl8139`, `pcnet`, `e1000`, `ich9-ahci`, `qemu-xhci`, `usb-kbd`) (V).

**DoD sources (DRAFT 4):**
- Cypoe/plex-shell @ `f34e473f`: `crates/plex-os/src/cyberboot.rs`, `crates/plex-os/assets/*.anim`, `crates/plex-libs/src/anim.rs`, `docs/4_origins_and_archaeology/04_VAND_AND_PROVENANCE.md` (V).
- Cypoe/boot-animator @ `d1e5d49b46887ddf4a78c1a77b0e266a7e739bb7`: `src/main.rs`, `Cargo.toml` (V).
- korulang/koru-libs @ `ff5cb559`: `unikraft/blk/README.md` (V read; its measurements C).
- Hyprland: `hyprland.pc.in` and CMake dependency list (github.com/hyprwm/Hyprland), Debian Hyprland team tracker (0.56.2, aquamarine 0.15.1, hyprutils 0.14.2), AUR `hyprland-git` (C, read 2026-10-18).
- Quickshell: quickshell.org and quickshell.outfoxxed.me/docs/about (C).
- Unikraft: `app-elfloader` README, syscall-shim docs, v0.10.0 release notes (futex, epoll, eventfd), `unikraft/catalog` `library/node/18/Kraftfile` (C).
- Box: QEMU 10.0.13 device and display lists; `/dev/kvm` permissions; `which` for fsck/strace tools (V, 2026-10-18 13:05 CEST).

**Background (C):**
- Redell, capability revocation via indirection (1974).
- Vahldiek-Oberwagner et al., ERIM (USENIX Security 2019).
- Hedayati et al., Hodor (ATC 2019).
- Watson et al., CHERI ISA (UCAM-CL-TR-951 and later).
- Xia et al., CHERIvoke (MICRO 2019).
- Filardo et al., Cornucopia (S&P 2020).
- Amar et al., CHERIoT (MICRO 2023).
- Plate, Holographic Reduced Representations (1995).
- Kanerva, hyperdimensional computing (2009).

---

## Appendix A. Security model: doc claim vs code (plex-shell @ `f34e473f`)

| claim (doc, class C) | code (V) | verdict |
|---|---|---|
| App silos are isolated, capability-bounded containers (glossary; thesis §6.2) | `AppSilo` is a bookkeeping struct; `launch_silo` returns mock PID `4000+n`; no process, domain or memory boundary | asserted |
| Atomic update with health check, instant rollback (thesis §6.2; manual 06) | `update_silo` overwrites unconditionally; `rollback_silo` (desktop) re-points a string; `rollback_silo` (multikernel) returns checkpoint metadata with `timestamp: 1000`; plexd `silos.rollback` is canned JSON | asserted; no content is restored |
| Capability tokens instead of privilege rings (ch.06) | `CapAddress` is a public enum of strings resolved through a `HashMap` to a raw offset; capabilities are `Vec<String>` | forgeable names, not capabilities |
| Capability delegation (multikernel) | `delegate_capability` copies a string after a membership check | no attenuation, revocation or provenance |
| PCC verifies memory bounds and capability grant safety against Lean invariants (ch.03) | `pcc.rs` checks premise counts on string conclusions; not connected to Lean; no bounds check | toy |
| UCAN delegation chains with attenuation and TTL (ASP whitepaper §8.5) | `UCANLease` has signature, audience, verbs, path-prefix attenuation, expiry; no parent link | partial: no chain; refusals tested (M) |
| mesh.rs uses HMAC/SHA-256 (ARCHEOLOGY.md) | ed25519 DID signature | doc drift |
| Security via missing semantic anchors (ISA physics synthesis; quine crypto) | repeating 32-byte XOR | false as a security claim |
| `ephemeral.rs` provides subagent sandbox isolation (manual 03) | file absent | doc drift |
| SASOS removes CR3 switches (glossary) | hosted structs; plex-os runs ring 0 with no paging (M, Task 1) | asserted; no protection exists |
| Hardware capabilities | no CHERI, MPK or PKU anywhere; `TaggedWord` is 3 software tag bits | not claimed by the docs; koru-os rungs 2 and 3 are new |

## Appendix B. Ch.08 claim vs evidence

| claim (C) | evidence | status |
|---|---|---|
| `U(i,s,a,r)` holographic associative carrier | `SparseUTable` = `Vec<UEntry{i,s,a,r}>` (V) | exists as a clear-text relation only |
| von Neumann lookup is O(N) | general CS: hashed or indexed lookup is O(1) expected or O(log N) (C) | framing is incorrect as a baseline |
| `Steps ∝ 1/Density(U)` (inverse complexity law), "verified" | no such theorem in isar-proofs (V, grep); no benchmark (V) | unproven, unmeasured |
| O(1) contraction on SIMD/GPU | `contract` is a nested loop, O(N·M); CUDA backend delegates to CPU (V) | not implemented |
| constructive interference reinforces normal forms | no superposition or interference in code (V) | not implemented |

---

## Appendix C. DoD correspondence rows (Linux-ABI personality)

Row form (§3.2): `identity → binding | class | milestone`. The identity is the Linux
x86_64 syscall or ioctl name, namespaced `linux.sys.*` / `linux.ioctl.*` /
`linux.path.*`. The binding is the Unikraft library (L2), a koru proc (L3), a driver
silo (`silo:lkl`, `silo:kolibri`, via the C.4 rows), or `REFUSE` (loud, R-REF). Bindings marked C rest on Unikraft documentation, not on a
build by this author. All rows are D as koru-os rows. The final row list for each
milestone is the L1 `strace -f` trace, not this table.

### C.1 DoD-1 (filesystem)

| identity | L2 binding | note | M |
|---|---|---|---|
| `linux.sys.{openat,close,read,write,pread64,pwrite64,lseek}` | vfscore (C) | | M2 |
| `linux.sys.{newfstatat,statx,getdents64,mkdirat,unlinkat,renameat2,ftruncate}` | vfscore (C) | `statx` coverage unknown | M2 |
| `linux.sys.{fsync,fdatasync,sync}` | vfscore → ext2 driver → `unikraft/blk:flush` | flush ordering is an obligation | M2 |
| `linux.sys.fallocate` | REFUSE initially | ext2 has no native preallocation semantics | M2 |
| `linux.sys.mount` | REFUSE (mounts are image configuration, R-CFG) | | M2 |
| block transfer | `unikraft/blk:{read,write,flush}` (V lift) | | M1 |

### C.2 DoD-2 (shell, programs, cyberboot)

| identity | L2 binding | note | M |
|---|---|---|---|
| `linux.sys.{mmap,munmap,mprotect,brk,madvise}` | posix-mmap, ukvmem (C) | | M3 |
| `linux.sys.{clone,clone3,futex,set_tid_address,set_robust_list,rseq}` | posix-process multithreading, posix-futex (C) | `rseq`: REFUSE with `ENOSYS` is acceptable to glibc, but must be logged | M4 |
| `linux.sys.{execve,wait4,exit_group,kill,getpid,getppid}` | posix-process (C) | | M3 |
| `linux.sys.fork` / `vfork` | `fork`: refused (no `CLONE_VM`-less clone, B20); `vfork`: posix-process, compat layer under Spawn (§8.6.4) | gates real shells; Hyprland `exec` (M9 h2) | M5, M9 |
| `linux.sys.{rt_sigaction,rt_sigprocmask,rt_sigreturn,sigaltstack}` | uksignal (C) | SIGUSR1 delivery is the T-CYB end condition | M4 |
| `linux.sys.{epoll_create1,epoll_ctl,epoll_wait,eventfd2,pipe2,socketpair}` | posix-event, posix-pipe, posix-unixsocket (C) | tokio reactor | M4 |
| `linux.sys.{clock_gettime,nanosleep,clock_nanosleep}` | posix-time (C) | | M4 |
| `linux.ioctl.TIOCGWINSZ`, `TCGETS`/`TCSETS*`, `TIOCSPGRP` | missing: tty line discipline (D) | `/dev/tty1` path row too | M4/M5 |
| `linux.path./dev/tty1`, `/dev/tty` | devfs (C) + tty driver (D) | | M4 |
| `linux.sys.{arch_prctl,prlimit64,getrandom,uname}` | posix-process/sysinfo/ukrandom (C) | | M3 |

### C.3 DoD-3 / DoD-4 (compositor, terminal, QML)

| identity | L2 binding | note | M |
|---|---|---|---|
| `linux.path./dev/dri/card0`, `/dev/dri/renderD128` | **none** (D: virtio-gpu driver) | | M6 |
| `linux.ioctl.DRM_IOCTL_{VERSION,GET_CAP,SET_CLIENT_CAP,SET_MASTER,DROP_MASTER}` | none (D) | | M6 |
| `linux.ioctl.DRM_IOCTL_MODE_{GETRESOURCES,GETCONNECTOR,GETENCODER,GETCRTC,GETPLANERESOURCES,GETPLANE,OBJ_GETPROPERTIES,GETPROPERTY,GETPROPBLOB,CREATEPROPBLOB}` | none (D) | | M6 |
| `linux.ioctl.DRM_IOCTL_MODE_{CREATE_DUMB,MAP_DUMB,DESTROY_DUMB,ADDFB2,RMFB,SETCRTC,PAGE_FLIP,ATOMIC}` | none (D) | aquamarine uses atomic or legacy KMS | M6/M9 |
| `linux.ioctl.DRM_IOCTL_{GEM_CLOSE,PRIME_HANDLE_TO_FD,PRIME_FD_TO_HANDLE}`, `read()` of DRM events | none (D) | vblank/flip events must be `epoll`-able | M8/M9 |
| virtio-gpu 3D (virgl) ioctls | none (D) | later; llvmpipe first | after M9 |
| `linux.path./dev/input/event*`; `linux.ioctl.EVIOCG{BIT,NAME,ID,ABS,KEY}`, `EVIOCGRAB`; `read(struct input_event)` | none (D: virtio-input → evdev) | | M7 |
| udev: `linux.path./sys/class/{drm,input}/…`, `/run/udev/data/*`, `NETLINK_KOBJECT_UEVENT` | none (D); posix-netlink exists (C) but not uevents | static seed acceptable at first | M7 |
| seat: `libseat` (seatd socket or builtin) | userspace seatd on the arm (D) | | M9 |
| `linux.sys.{memfd_create}` + `fcntl(F_ADD_SEALS)`, `ftruncate`, `mmap(MAP_SHARED)` | unknown (memfd in Unikraft not confirmed) | `wl_shm` buffers, foot | M9 |
| `linux.sys.{sendmsg,recvmsg}` with `SCM_RIGHTS` on `AF_UNIX` | posix-unixsocket (C); fd passing unconfirmed | every Wayland client | M9 |
| `linux.sys.{timerfd_create,timerfd_settime,signalfd4}` | posix-timerfd (C); signalfd unknown | wayland event loops | M9 |
| Qt 6 / QML runtime (fontconfig, freetype, harfbuzz, ICU; possibly D-Bus) | inherits all rows above, plus a larger `mm.*`/`fs.*` set | | M10 |

### C.4 Driver row set (DRAFT 5): the only exports a driver silo may have

| driver row | upper identities it serves | silo:lkl binding | silo:kolibri binding |
|---|---|---|---|
| `blk.{info,read,write,flush}` | vfscore → ext driver, or DS1 internally | Linux block layer on `virtio_blk` (?) | `virt_disk`/AHCI service (D) |
| `fs.*` (DS1 only) | `linux.sys.*` file rows of C.1 | LKL ext4 via `lkl_sys_*` (?) | refused (no silo-ready FS) |
| `net.{tx,rx,link}` | posix-socket / lwIP netdev | `virtio_net` (?) | `RTL8139`, `pcnet32`, `i8254x` (D) |
| `kms.{version,getcap,getresources,getconnector,getencoder,getcrtc,getplane*,getprop*,create_dumb,map_dumb,destroy_dumb,addfb2,rmfb,setcrtc,page_flip,atomic,gem_close,prime_export,event}` | `linux.ioctl.DRM_IOCTL_*` of C.3 | whitelisted forward to LKL `/dev/dri/card0` (`virtio_gpu`) (?) | translation to `vmwgfx` service (D) |
| `input.{caps,name,grab,event}` | `linux.ioctl.EVIOCG*`, `read(input_event)` of C.3 | LKL evdev on `virtio_input` (?) | `usbhid`/`ps2mouse4d` events translated (D) |
| anything else | n/a | **REFUSE** | **REFUSE** |
