# DESIGN-0001: The koru-os execution contract

Status: DRAFT 5, 2026-10-18 (DRAFT 1 07:51; DRAFT 2 07:58: §2 replaced by a pointer to the ccomp concordance matrix, "arm" renamed "platform arm"; DRAFT 3 08:05: §8 security target model, §9 associative memory as a later rung, Appendices A and B; DRAFT 4 13:08: §0 Definition of Done set by Fabian (DoD-1..4, arm analysis, cyberboot, milestones M0–M10), R-DOD rows, Q16–Q22, Appendix C; DRAFT 5 19:26: Fabian's rulings: L1 is oracle only, driver silos (LKL accepted, KolibriOS second source), QML as canonical DoD-4 exemplar, DS0–DS4, R-SILO, Q17/Q20/Q21 closed, Q23–Q27) (Europe/Berlin, CEST). Owner: koru (agent) for Fabian Schindler.
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
    and `posix_spawn`/`vfork` may suffice for `ash` with job control off (Q19).
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
| M2 | real FS allocates blocks (**DoD-1**) | L2: vfscore + ext2 driver, **or** DS1 | guest creates `/dod1` of *N* blocks, writes, `fsync`s, halts; host `e2fsck -fn` clean, `debugfs -R 'cat /dod1'` equals pattern, free-block count dropped by ≥ *N* | **M (TCG), 2026-10-18**: minimal ext2 Koru lift (`koru/ext2`); 3/3 + 1 runs pass, e2fsck exit 0, free blocks −10, inodes −1 (`experiments/m2-ext2/`). Scope: one file, one group, direct blocks, no vfscore yet |
| M3 | static busybox shell from the ext root | L2 `app-elfloader` (L1 trace first) | scripted serial session: `echo`, `ls /`, `cat /dod1`, `exit 3` → exit status 3 observed; refusal log empty or only by-design rows | **partial M (TCG)**: static-PIE NOMMU busybox hush on app-elfloader, initrd root; interactive serial session works and vfork+execve applets run; pipelines and redirected external commands crash (SIGSEGV in vfork child?); not yet from the ext root (`experiments/m3-busybox/`) |
| M4 | **T-CYB** (§0.2) | L2 (L1 trace first) | (a)–(e) of T-CYB | D; runs on the labelled stand-in until the newer boot-animator is pushed (Q18) |
| M5 | real programs, dynamic linking (**DoD-2**) | L2 | musl, then glibc, `ld.so` run coreutils and an interactive `ash` with a pipeline (`ls \| wc -l`); T-CYB still passes | D |
| DS2 | Kolibri driver silo, first driver | L2 + silo:kolibri (KolibriOS driver-service personality) | an unmodified KolibriOS `.sys` network or input driver (`RTL8139`/`pcnet32` on QEMU `rtl8139`/`pcnet`, or `ps2mouse4d`) loads in the silo. Its imports either bind to rows or are refused by name. `net.*` frames or `input.*` events cross the silo boundary (serial log) | D |
| DS3 | GPU driver silo | silo:lkl `virtio_gpu` on `virtio-gpu-pci`, or silo:kolibri `vmwgfx` on `vmware-svga` | the silo exposes only the `kms.*` rows of Appendix C.3; M6 passes through it | D |
| DS4 | input driver silo | silo:lkl `virtio_input` (evdev) or silo:kolibri `usbhid`/`ps2` translated to `input.*` | M7 passes through it | D |
| M6 | KMS scanout of a dumb buffer | L2 + DS3 (L1 trace first) | libdrm `modetest -s <conn>:<mode>` (or equivalent) draws a test pattern; screendump pixel check at known coordinates | D |
| M7 | input | L2 + DS4 | QMP `input-send-event` key events appear in `libinput debug-events` on serial | D |
| M8 | GL on KMS | L2 + DS3 + Mesa llvmpipe/`kms_swrast` in userspace | `kmscube` runs; two screendumps 1 s apart differ, and both are non-black | D |
| M9 | **DoD-3**: Hyprland + foot | L2 + DS3 + DS4 | screendump shows a foot window; QMP keys type `echo DOD3 > /tmp/dod3`; `hyprctl -j clients` lists class `foot`; after shutdown the host reads `/tmp/dod3` from the image | D |
| M10 | **DoD-4**: QML exemplar | same as M9 | a quickshell bar on a layer-shell surface is visible in a screendump; editing its QML changes the next screendump without a restart | D |

Every row above has an **L1 twin run** that produces the reference trace and
screendumps. That twin is filed as oracle evidence and is never counted as a pass.

Order of risk: M2 and M3 are bounded engineering. M5 is gated by `fork` (Q19). DS1 and
DS3 are gated by the LKL host port onto Unikraft and by device access from inside a
silo (Q25). DS3 is the largest item in this note, and its size is unknown.

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
| `correspondence row` | symbol-resolution record plus provenance (linker / NID table) | persistent: foreign name ↔ minted interface ↔ provider, with lineage and evidence | not yet in tree (koru-os) |
| `live binding` | resolved PLT/GOT entry / capability handle | ephemeral: carries instance, generation and an obligation lifetime | not yet in tree (koru-os) |
| `generation` | epoch / incarnation number | a stale generation is refused at use, never redirected | not yet in tree (koru-os) |
| `evidence class` (V/M/C/D) | provenance level / assurance level | verified-now, measured, carried-over, design-only | not yet in tree (koru-os) |

---

## 3. The execution contract

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
| configure | a required interface has no row for the selected platform arm | **D**: this note's first slice (§11) |
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
- This is an open research question (§12), not a decision. It must be tested against
  the three verified specimens before anything is built.

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

**Out of scope for the slice:**

- the microkernel platform arm
- counting and revocation (§6.4)
- KolibriOS translation
- plex-os platform arm rows beyond `PlexGuestBoot` as a documented row

---

## 12. Open questions

1. **Counting wall.**
   - Is a store-held count plus epoch (§6.4) enough for the three specimens: refcount,
     CR3 singleton, sibling fids?
   - Or does Koru need a counted phantom form (fractional permissions, or a multiset
     typestate)?
   - What is the cost in compile-time checking versus runtime checks?
2. **Snapshot sharing.** Can every shared-read case be expressed as a frozen,
   content-addressed region, so that counting is needed only for mutation? What breaks
   (DMA buffers, rings)?
3. **NID derivation.**
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
    `KolibriOS/kolibrios` @ `69df0061`.
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
| `linux.sys.fork` / `vfork` | unknown (Q19) | gates real shells | M5 |
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
