# PLAN — koru-os, free-standing

The destination: **koru-os is a free-standing OS**, not a Unikraft unikernel
with extras. Unikraft and KolibriOS are *donors* — reusable substrate,
drivers, ABIs, behavior — and Hyprland/Quickshell/Noctalia are *oracles*
(conformance references), not the host.

## What is owned (non-negotiable, koru-native)

| layer | owns |
|---|---|
| identity | `nid` — object pins + correspondence rows; nids are resolvable references, not names |
| seams | syscall seam, provider dispatch, spawn/exec, rights bags |
| realization | `std/realize` vocabulary + `koruos/realize` policy — rows bind arms, loudly or not at all |
| views | POSIX paths, the relational store, the SAS-silo memory model |

## What can stay extern (donor or oracle)

- **Drivers** — extern is fine. What must be owned is the *provider contract*
  they plug into, not the register-poking.
- **Userland / programs** — shells, compositors, apps can be extern code
  (even Hyprland before `nativeCompositor` exists) — as long as they ride
  koru-os seams, not the other way around.
- **Memory internals** — extern allocators are acceptable; the owned part is
  the model: **single-address-space silos that virtual memory maps onto**
  (a silo is the object; VM/CR3 is a projection of it).
- **Filesystem internals** — extern fs implementations are acceptable; the
  owned part is **relational object storage underneath, POSIX as a view**.
  Paths are projections over nid-pinned identity — `lookup`/`pin`/`exec-nid`
  already prove the direction on ext2.

## Donors

| source | role | state |
|---|---|---|
| `upstream/unikraft` (+ koru-libs `unikraft/*`) | provider dataset, driver ABI, arm `unikraft/*` | vendored, actively used |
| `upstream/kolibrios` | second donor: fasmg source, drivers, full GUI stack — not yet mined | vendored, unstudied |
| Hyprland / Quickshell / Noctalia (`m9src/*`) | compositor+shell **oracle** — behavior reference for `nativeCompositor` | pinned |

### The open ABI question (decide before driver count grows)

Today the lifts speak Unikraft's ABI (`uk_blkdev_*`, `ukplat_*`,
`uk_alloc`) and the native provider *implements* that ABI in
`koru/native/*.zig`. Two honest options:

- **(a)** keep `uk_*` as a private ABI forever — legitimate; an ABI is
  just an ABI, and unikraft stays a first-class arm.
- **(b)** define `koruos.blk.*` (etc.) as the owned provider contract and
  make unikraft an *adapter* onto it — the honest "not a unikernel"
  answer, and a re-plumb of every lift extern. Every new driver added
  under (a) makes (b) more expensive.

Same question applies to fasmg/KolibriOS material: KolibriOS is a
full GUI OS in flat assembler; its syscall ABI (int 0x40), driver model,
and VFS are donor-shaped — an adapter arm, not a substrate to inherit.

## Personalities: same platform, different magic

`exec` already dispatches on the object's magic — ELF64 is simply the
one personality implemented today. The seam generalizes: **a magic
selects a personality, and a personality is a provider family**, not a
kernel fork. Consequences:

- **DOS programs run on this platform.** An `MZ`/`COM` magic dispatches
  to a DOS personality: a vm86 monitor (or a real-mode trampoline on
  hardware that allows it) plus an `int 21h` service family realized
  through koru providers (fs.object for file ops, console, memory).
  Dependencies of the DOS program itself are out of scope; the ABI it
  expects is not.
- **KolibriOS apps are the same shape** — `MENUET01`-magic binaries +
  `int 0x40` service family, realized against koru providers. The
  vendored tree is the ABI reference for exactly this.
- The personality boundary is where foreign ABIs get *contained*: each
  family translates its syscall convention into koru seams, so a DOS
  program's `int 21h` file-read becomes an `fs.object` call — the
  program never escapes the nid/rights-bag model.
- Explicitly **not** pursued: importing an LKM stack or embedding a
  Linux kernel to gain compatibility. Personalities give the
  compatibility surface without adopting a host kernel's architecture.

## Hosted-first: the nix-shaped slice

The first *free-standing* milestone doesn't need bare metal. The
identity layer — nid store, realization rows, link-time refusal,
rights bags — is host-agnostic; a hosted arm realizes provider seams
over the host kernel's syscall ABI. That's nix's shape transposed:
nix = content-addressed store + link-time composition over Linux;
koru = nid-addressed storage + realization rows over providers. The
concrete slice: **koru system interpreter + on-disk nid store +
link-time provider binding**, with the bag enforced (seccomp on
Linux), not advisory.

Host arms, deliberately plural:

- **`hosted/linux`** — first, because the toolchain, the WSL bench,
  the linuxu donor arm, nix's precedent, and the Hyprland oracle all
  live there. Capabilities are synthesized: seccomp-bpf (an NR bitmask
  — exactly what bags are today), Landlock for fs scoping, namespaces
  for uid scoping. Weak native object-capability story.
- **`hosted/freebsd`** — early second arm, not for coverage but as the
  **design test**: Capsicum is the bag design already — capability
  mode + named rights on descriptors (`CAP_*`), casper = provider
  family. If nid-scoped grants collapse onto `cap_rights_t` without
  special-casing, the capability model is honest; if they can't, the
  model learns why cheaply. OpenBSD pledge/unveil noted but coarser —
  promise strings, not per-object grants.

Risk to hold: a hosted arm alone is "another userspace runtime" —
it's koru-os only while unbound providers refuse before execution and
nid storage is the primary identity, on the host exactly as on metal.
The bare-metal ladder below stays the path to `koru-native`; hosted
shortens the feedback loop on identity/realization, it doesn't replace
the kernel work.

First system milestone on this track: **the koru interpreter as the
system REPL** — init = interpreter over the host terminal; prompt →
exec-by-nid children under enforced bags → reap → repeat. It's the
only slice exercising the whole chain at once (terminal IO, provider
dispatch, spawn, isolation, persistent nids, loud refusal). The eval
path already exists: `koru_std/interpreter.*` parses koru at runtime
with the compiler's own parser and dispatches tors registered via
`std/runtime:register(scope:)` — **the scope is the capability
surface**: a shell registers os providers into a scope; a child's
bag can literally be *which scope its interpreter gets*. The
remaining pieces are the REPL driver program (read → `run(source:,
scope:)` → print) and the os-scope registration, not an
interpreter.

**Landed: the system REPL** (`koru/hosted/tests/repl.kz`, gated by
`check-hosted.sh` — 12/12). Boot mounts blkdev 0 and hands the
mounted-fs obligation to `repl(fs: *Fs<!mounted>)` — the capability
moves into the process by handoff, discharged via the os-scope
`unmount` verb. Each terminal line is a full koru flow through
`std/interpreter:run` against `dispatch_os`; session_env keeps
bindings durable across lines. Scope verbs call provider tors **by
name from zig** (`koru_koruos.koru_ext2.X_event.handler`) — which is
why the ext2 surface carries `~[retain]`: the declared mechanism for
tors invoked outside flow reachability. Proven in the gate:
interpreted `exec(path:)` runs a real host child (status 43),
`pin` mints nid identity from source, `bogus()` refuses at dispatch
(`EventDenied`), an unbound nid refuses by name. Two honest limits:
wrapper tors inject `fs` from module state (interpreter `Value`
carries branch+fields, not pointers — the `handle_pool`/spec fns are
the deeper mechanism, deferred), and verbs return flat strings
rather than typed Values.

**Landed: REPL on `std/bridge`** (17/17 hosted). `cur_fs` is gone —
the boot-mounted `*Fs` is minted as a pool resource token
(`h:Fs:…`), handle-acquired with `unmount` as its discharge verb
(obligation names derived from the scope's spec table, not spelled
twice), and bound under `fs` in the session env. Scope verbs take
`string<mounted>`/`string<!mounted>` token args; the procs resolve
them via `resolveDispatchResource` — the typed pointer never
crosses `Value`. Proven mid-session: `unmount(fs: fs)` discharges;
the same `pin(fs: fs, …)` afterwards refuses *by name* ("names
nothing the session holds"); a `mount()` handle left open is
released at `close` through the real `unmount` dispatch. Required
pin-local patch: `~[retain]` on bridge `create`/`run`/`close`/
`get-handles` (host-text callers; upstreamable).

**Landed on this track** (gated by `scripts/check-hosted.sh`):
`koru/hosted/linux.zig` realizes the whole lift extern surface on
host primitives — file-backed `uk_blkdev_*` (`$KORU_BLK0`, requests
complete inline), `fork+execve+waitpid` spawn (rights bag advisory,
printed not enforced — seccomp is the named future mechanism), and
a **persistent** nid store (`$KORU_NID_STORE`) with identical
mint/refusal semantics to native. `hosted_ext2` proves the same
chain `boot_ext2` gates: mount → exec(path) → pin → exec-nid →
child ran twice as a real host process, nid survived process death.

**`hosted/freebsd` (Capsicum arm, build-checked)** —
`koru/hosted/freebsd.zig` + shared `common.zig` (file-backed blkdev,
clock, nid store; spawn is the per-OS seam). The spawn path is where
the bag stops being advisory: parent opens the staged image once,
narrows the fd to `CAP_READ|CAP_FEXECVE|CAP_FSTAT` via
`cap_rights_limit`, then `pdfork → cap_enter → fexecve(fd)` — the
child runs in capability mode with no path namespace; the image fd
is its grant. The semantic check already bit twice: `stdout` is
`__stdoutp` on FreeBSD libc (say now writes fd 1), and the koru
`rights` u64 is an **NR bitmask** (which *calls* you may make) while
`cap_rights_t` is **per-descriptor** (which *objects*, how) — the
nid-scoped grant-object bag is the Capsicum axis; NR bits without a
descriptor analogue are reported unmapped, not silently granted.
Caveat for the real run: cap-mode children must be static — a
dynamic ELF's rtld opens libs by path and ECAPMODEs.

**`spawn:hostexec` — real ELF by host path (hosted-only, gated)** —
where `exec` crosses the seam with image *bytes* (identity: the
content, nid-bindable from ext2), `hostexec` names a path in the
*provider's own* namespace: no bytes cross, the host kernel loads
it — real ELF64 including PT_INTERP, dynamic linking via the host
ld.so. Gated live: `/usr/bin/busybox` echoes through the wire and
`/usr/bin/false`'s exit status propagates back (28/28 hosted).
argv v0 is one space-split string — argv-as-data on the wire is
the eventual shape. Arm honesty: on `koru-native` there is no
host namespace — the extern is absent and a program naming the
verb refuses at link; on `hosted/freebsd` cap mode narrows the
opened path fd and `fexecve`s it, so dynamic host paths still
fail inside ld.so by design. This is the first rung of real-ELF
hosting; the native ladder under it landed next:

**Real ELF children on koru-native (boot 24/24)** — the loader
grew from "embedded hand-built ELF in a 2 MiB window" to a real
image path. Child address space: user half is its own pdpt slot
(`pdpt[1]` → `upd`, `0x40000000–0x7FE00000`) so kernel identity
and ISR-on-child-CR3 stay intact; pts grow on demand; `freeChild`
walks the upd and reclaims every pt + page. `loadElf` serves
ET_EXEC inside the window and ET_DYN via bias (the same mechanism
PT_INTERP will need); PT_INTERP refuses by name until the rung
below exists. The child gets a real initial stack — argc/argv/
envp/auxv with AT_PHDR (in-image or a parked copy), AT_RANDOM —
and the syscall seam grew the surface a real libc demands:
writev, brk, anonymous-private mmap (file-backed → ENODEV),
arch_prctl FS base switched per-child via MSR, getpid at the
real NR 39, ioctl→ENOTTY, prlimit64, getrandom, exit_group.
Bag bits became *capability indices*: canonNr folds NRs ≥64
onto reserved caps (62 proc-self, 61 entropy, 231→60). ext2
reads follow single+double indirect (files to ~66 MiB) so a
~1 MB musl image actually reaches the loader. Gate evidence
(`boot_real.k`): a gcc `-static-pie` ET_DYN and a full
**musl-static `puts`** binary ran to status=42 with zero seam
refusals — 67 frames reclaimed on exit.

**fs-in-child — the scoped fs view (gated)** — a child's `open`
now resolves *inside the fs its image came from*: `koru_spawn_elf`
takes a 4th arg, an ops record (`open/read/read_at/seek/stat/close`)
the spawning fs hands down — ext2's `exec`/`exec-nid` pass their own
`Fs` plus ops; `spawn:exec` and the embedded path pass `null`, so
children spawned from raw bytes get `open() == -ENOSYS`, never a
borrowed fs. The kernel side owns only fds 3..7 + child-memory copies
(via the identity map, W-bit-independent); the provider owns handles
(`OpenFile{ino,pos}`), path resolution (`lookupPath`), and the
partial read (`readAt` walks blkAt per covered block — whole-file
`readFile` stays for exec). Surface: `open`/`openat` (257 folds to
cap 2), `read`, `close`, `lseek`, `fstat` (144B linux stat), `pread64`.
The view is writable now — `O_WRONLY`/`O_RDWR`/`O_CREAT`/`O_TRUNC`
serve through `cfWrite`/`mkfile` (direct blocks, ≤12KiB — larger spans
refuse ENOSPC by name), `rename`/`unlink` mutate directory entries,
`write`/`writev` dispatch on the fd's recorded verbs (fdverbs — the
projection IS a grant), and object-scoped `W` grants name the mutated
object: the file for write-open, the parent directory for
create/unlink/rename. `boot_ext2.k` measures `pin → rename →
exec-by-nid` — the post-rename exec resolves the same inode, the stale
path refuses, and host-side debugfs finds `moved.elf` on the pin's
inode after QEMU exits. Gate evidence
(`boot_real.k`): **a real musl binary `open()`/`read()`/`close()`d
`hello.txt` on its own ext2 and printed the bytes** — file contents,
not just the image, now reach ring-3. This is the PT_INTERP rung's
prerequisite (ld.so's DT_NEEDED loads are `openat`+`mmap`-file), and
the first half of what a real shell needs — a child that can name
paths. The bug it exposed: `arch_prctl(SET_FS)` recorded the base but
only `resumeChild` wrote the MSR — muslhello survived on a preemption
tick's incidental reload; the fix writes FS_BASE before sysret on the
prctl path itself.

**PT_INTERP — real dynamic ELF (boot 28/28)** — the loader now runs
genuinely dynamic binaries. `loadElf` parses PT_INTERP; the interp
path resolves through the child's *own* fs view (`loadViaFs` — open
+ read_at, streaming headers through a 4 KiB stack buffer and each
PT_LOAD straight into its mapped pages — no whole-file copy, the
4 MiB bump heap can't afford a second ld.so), lands as a second
ET_DYN at `INTERP_BASE`, and `AT_BASE` rides the auxv. File-backed
mmap is a copied private mapping (pages via `read_at`; `mprotect`
honors the W-bit — PROT_EXEC advisory without NXE). The bug a real
loader exposed: musl `map_library` reserves spans PROT_NONE then
MAP_FIXEDs each LOAD with its real prot — prot must apply to
*reused* pages, not just fresh ones, or GOT writes fault RO.
ext2 went multi-group with the payload (inodeLoc reads the GDT;
create allocates per-group bitmaps+counts; sparse holes read as
zeros). `canonNr` grew `openat→2`, `exit_group→60`, entropy→61,
proc-self→62, `fcntl→62`; `uname(63)` answers `koru-os`.
`scripts/stage-dynamic.sh` pulls pinned Alpine v3.22 apks onto the
16 MiB image. Gate evidence (`boot_real.k`): `HI=41` — a zig pair
(`hi.elf` + `liblibhi.so`) crossed a *non-self* DSO boundary
(openat→file-mmap→reloc→call); **BusyBox v1.37.0** ran its full
applet dump through musl ld.so; **GNU coreutils `uname` ran a
5-lib closure (libcrypto/libacl/libattr/libutmps/libskarnet —
the `cfs open` trail is the search order) and printed `koru-os`** —
a current-distro userspace binary, not a fixture. Legit refuses
on the trail (getuid=102, prctl=157) are the loud axis, not bugs.
`build-hosted.sh <prog> [out] [shim]` selects the shim; check-hosted
asserts both fixtures link for `x86_64-freebsd` (no linux-only
primitive may leak into the shared seam).

**`koruos/surface` on the hosted arm (linux-x11, gated)** —
`koru/surface/index.kz` is the compositor-facing lift, deliberately
split from `koruos/fb` (the dumb device): `open` mints
`*Surf<open!>` into the bridge pool, `fill`/`px`/`present` borrow
`*Surf<open>` through the pool token, `close` consumes
`*Surf<!open>`. Realization is `koru/hosted/x11.zig` over
`libX11.so.6` — a real compositor (WSLg), not a PPM: the surface is
a mapped X window backed by one provider-owned ZPixmap; `present`
is `XPutImage`+flush. `build-hosted.sh linux-x11` is a separate arm
variant (glibc-dynamic; the static `linux` arm must not even see
the X11 externs — `repl.kz`/`repl-x11.kz` split at exactly that
seam). Proven through the same bridge path as fs: `surf() | ok o |>
bind(name: "s", value: o.surface)` mints `h:Surf:…` into the pool;
`fill/present(surface: s)` resolve on later turns; `sclose`
discharges; re-use refuses *by name*; an unclosed surface is
released at bridge `close` through the real provider verb; and
`xwininfo` reports the mapped 640×480 "koru-os" window — the
compositor's own account, not ours.

**`koruos/surface` on koru-native (gated)** — `koru/native/surf.zig`
is the surface-over-fb provider family the paragraph above was
waiting on: a pool of provider-owned backings (contiguous pmm
frames), open mints `*Surf<open!>` into the pool, fill/px touch the
backing only, present(damage) blits through the fb seam and commits
through `fb:present` (TRANSFER+FLUSH on vgpu). Placement is the
provider's own cascade — the dumb-WM authority; painter's order at
present is the only z-rule, real stacking is `nativeCompositor`'s
cell. The fixture's phantom types do their own work: every arm of
`boot_surf.k` must discharge its live `*Surf<open!>` via `close` —
linearity is the leak check. Evidence is the screendump, which is
the row's actual point: serial printed `SURF COMPLETE` while an
offset-semantics bug (TRANSFER's `offset` is the rect's byte offset
in the *strided* backing, not a packed buffer start) doubled every
sub-rect — the pixel readback caught what self-report could not.

**What the X11 oracle just taught the kernel ladder** (why this
came before the frame allocator): a surface is *a persistent
backing buffer the provider owns* + a damage-less `present`
commit point + a lifetime (destroy releases the window object and
the buffer together). For native that translates to: (1) the
frame allocator must hand out **long-lived, physically-stable
buffers** — a surface is not a heap alloc, it's pinned scanout
memory with a lifetime tied to a resource handle; (2) present
needs a **commit/dirty boundary** — XPutImage copies the whole
buffer each time; wayland/vulkan want damage rects, so the native
contract should carry `present(surface, damage)` even if the
first provider ignores it — **now realized**: `present` takes
`x,y,w,h`, an empty rect refuses, and XPutImage blits only the
sub-rect; (3) close is a **pair-release** —
window object + backing store die together, which is exactly the
bridge discharge's shape. X11's copy-model also names what to skip:
no event loop (input is a different provider family) and no GPU
submission — virtio-gpu stays its own axis.

**`koruos/input` on both arms (gated)** —
`koru/input/index.kz` is the shared human-input lift: `poll`
returns one queued event or `empty` — never blocks (sleeping is
the wait-queue rung's problem, not the iface's shape). Events are
**raw**: `key` carries the provider's hardware code (set-1 scancode
native, X keycode hosted) — charmap is a layer above; `motion` is a
delta; `expose` is damage flowing *server→client* (a repaint
demand — see below). Realized by `koru/native/kbd.zig` (8042 IRQ1 →
64-entry ring, drain-on-poll covers edges lost while masked) on
`koru-native` and by `x11.zig` (XSelectInput + XPending drain on
the same connection that owns surfaces) on `hosted`. Evidence:
QEMU `sendkey a` → IRQ1 → `KBD key code=30 pressed=1`; python
ctypes `XSendEvent` → the painter's event loop. The *same* event
vocabulary on both arms — neither provider got to bake semantics
in alone.

**The Expose lesson** — the painter's first run proved it: pixels
presented before the window is viewable get wiped by the server's
background repaint; only post-map presents stick. The honest fix
isn't a delay or a flag — it's the `expose` event: the server
*demands* a repaint and the client obliges. Damage is bidirectional,
and the contract now says so. This is the compositor fact the
native side must internalize before `nativeCompositor` — a surface
isn't "write and show", it's "hold a scene and repaint on demand".

**`koru/hosted/tests/painter.kz` (gated)** — the koru-written
compositor shape, hosted arm: owns a surface, composites its own
scene (bg + fixed fg + a moving box drawn last), polls input,
repaints on `expose`, presents per-rect damage, quits on 'q'
(X keycode 24 — a named key, not "any event": focus/modifier
traffic is real input). `scripts/xprobe.py` is the gate's witness —
ctypes→libX11 `XGetImage` reads the composite back off the *server*
(0x202040 bg + 0xC04000 fg pixels), `XSendEvent` drives the quit
key. The driver calls the lifts' emitted `*_event.handler`s
directly — typed `*Surf` inside one process; the bridge pool stays
the wire-facing custody path.

**`hosted/vroot` — the vendored-userspace desktop path (gated)** —
Ubuntu-20.04 WSL cannot package a real terminal, compositor, or
webview, so `hosted/vroot/` carries an **Arch rootfs** built by
`scripts/mk-vroot.sh` (`docker build` → `docker export` → `~/kvroot`)
and entered via `unshare -Urmpf` + chroot — no root, same kernel,
no daemon bridging. The jail membrane is measured
(`concepts/frag-vroot-jail-membrane.md`): foreign-tmpfs binds are
refused so WSLg sockets ride `vroot-relay.py` with **SCM_RIGHTS**
fd-passing intact (wayland keymap/shm-pool die in a byte-pump);
`mknod` is EPERM so `/dev` is fresh tmpfs + devpts + symlink/fifo
fakes (an EOF-returning `/dev/urandom` sends WebKit's entropy init
into a 100%-CPU read loop). `hostexec` reaches the jail unchanged —
the spawn seam's *empty envp* is a feature: ambient env is a leak
channel, entry scripts resolve their own PATH/HOME. Gated rows:
real `foot` terminal negotiated WSLg through the relay; **nested
weston** served `foot` on `wayland-1` — two levels of real
compositing on the hosted arm; **`kvview` (vendored webkit2gtk)
rendered a page and read back the DOM title** — the webview rung
the user asked for; and a measured-refusal oracle: **hyprland
(aquamarine) requires `zwp_linux_dmabuf_v1`** — WSLg is software,
no dmabuf, no `/dev/dri` — the row pins *why* so a dmabuf-capable
environment flips it on contact. Hyprland-as-protocol stands —
and the koru-side wayland provider now exists:

**`linux-wayland` — the second hosted surface arm (gated)** —
`koru/hosted/wayland.zig` implements the same `koruos.surface` +
`koruos.input` extern surface as `x11.zig` over libwayland-client:
registry binds `wl_compositor`/`wl_shm`/`xdg_wm_base`/`wl_seat`, a
surface is an xdg_toplevel on a `memfd`-backed `wl_shm` buffer —
`present` is `damage_buffer`+`commit` (the protocol's native commit
shape, no pixel copy), xdg `configure` doubles as the iface's
repaint-demand (`expose`), and evdev codes pass through raw. The
arm is **musl-static with the protocol stack vendored as source**
(`koru/hosted/wayland/`: scanner-generated bindings + libwayland
1.26.0 `src/` + alpine musl `libffi.a` — `VENDORED.md` records
provenance): host Ubuntu's libwayland is 1.18 and predates
`wl_proxy_marshal_flags`, and the vroot's 1.26 needs glibc 2.38 —
a vendored static stack beats both. Zero runtime deps: the binary
runs on the host and inside the jail unchanged. Gated rows: xdg
toplevel configure→ack→attach→damage→commit on WSLg's wire, the
same pool/contract semantics as x11 (empty damage + stale token
refuse, bridge discharges a held surface), and `painter.kz`
presents per-rect damage to the real compositor — one fixture
source, two realization arms.

koru-libs `origin/main` now carries the shell-authoring stack
(`clay` solver binding + `nativelayout` pure-koru candidate +
`ui` panel words + `oshun` markup→spec-rows) — *our* backend path
is `koruos/surface`, not `metal`. `nativelayout` emits a `CmdView`
command stream, not pixels — geometry only; hardware acceleration
is the renderer/provider's contract (framebuffer → virtio-gpu,
dmabuf where the host has it), never the solver's.

### KolibriOS donor map (first-pass read, `45b134ba`)

| ask | where it lives in `upstream/kolibrios` |
|---|---|
| syscall dispatch (kolibri personality spec) | `kernel/trunk/core/syscall.inc` — `servetable2` flat `dd` table, dual `SYSENTER`/`int 0x40` entry; fn 70 = `sys_file_system_lfn` (VFS seam), fn 77 = posix, `-1` = exit |
| runtime loading | `core/dll.inc` (`.obj` DLLs) + `core/peload.inc` (a PE loader — foreign-format load+bind, not ELF) |
| DOS/v86 personality mechanism | `core/v86.inc` — `v86_create` → `V86_machine` handle with `iopm` (I/O permission map) |
| fs providers behind one seam | `fs/fs_common.inc` + `fs_lfn.inc` over `ext/fat/exfat/ntfs/xfs`; `blkdev/disk_cache.inc` below |
| driver model / adapter precedent | `drivers/devman/` (+ imported ACPICA) and `drivers/ddk/linux/` — **Linux drivers wrapped in a compat shim: the adapter-arm pattern in the wild** |
| GUI/input (nativeCompositor oracle) | `gui/window.inc`, `gui/event.inc`, `hid/{keyboard,mousedrv}` |
| hw init | `core/{apic,irq,hpet,timers,sched,taskman,memory,heap,slab}.inc`, `bus/pci/pci32.inc` |

Not there — stay spec/vendored-driven: **real ELF + dynamic linking**
(Kolibri is `MENUET01` flat; references are `upstream/app-elfloader`
today, a later `upstream/musl` pin for ld.so — a Linux checkout would
pull gravity toward the LKM stack for no payoff), **IO-MMU/VT-d**
(32-bit physical addressing — virtio DMA programs guest-physical
addresses regardless, defer or spec-driven), **virtio-gpu** (absent;
first pixels come cheaper from a multiboot/GOP linear framebuffer —
the `cyberboot` path — with virtio-gpu later for damage/3D).

## Landed (koru-native arm, gated by `scripts/check-boot.sh` — 43/43)

- **pmm — the frame allocator + reclaim.** `koru/native/pmm.zig`:
  loader memory map (PVH `hvm_start_info` under QEMU `-kernel` —
  **correction**: the image was being PVH-booted all along; the mb2
  tag walk stays for GRUB) → u8-refcount bitmap over 4 KiB frames.
  `alloc`/`pin`/`free`/`allocContiguous(n, align)`/`alloc2M`/`freeBlock`;
  double-free and free-of-reserved refuse loudly. The identity map now
  covers all managed RAM (`_start` 0–32 MiB, `pmm.init` onward to the
  discovered limit, cap 1 GiB). Child page tables/pages/stacks moved off
  the bump heap onto frames; **`freeChild` on exit() reclaims all of
  them** (`pmm: reap freed=N` on serial — the pair-release shape the
  surface contract wants). aspace's proof window moved to pd[257]
  (0x20200000) and eats 2 MiB-aligned blocks — lesson recorded: a large
  PDE needs a 2 MiB-aligned base or the walk faults RSVD. The 4 MiB bump
  heap still serves koru-level malloc — program data, not page tables.
- **`koruos/fb` — display output through a dispatched backend.**
  `koru/fb/index.kz` lift (info/fill/px/**present** — draw and commit
  are distinct verbs; `absent` refusal) + `koru/native/fb.zig`
  dispatcher over three providers, ranked: mb2 mbi tag 8 (GRUB
  programs the mode), **virtio-gpu** (`gpu.zig` over `virtiopci.zig`
  — modern vendor-cap windows walked for common/notify/isr,
  VERSION_1 negotiate, split queue armed on MSI-X vector 48,
  GET_DISPLAY_INFO/CREATE_2D/ATTACH_BACKING/SET_SCANOUT; `present` =
  TRANSFER_TO_HOST_2D + RESOURCE_FLUSH), else **BGA** (std VGA
  VBE_DISPI + BAR0 LFB — QEMU's `-kernel` loader never answers the
  mb2 fb tag). Device windows and the GPU's backing frames map
  through `mmio.zig` — one identity-map owner, not a private `pd`
  per provider. Gate evidence is the QEMU-monitor screendump:
  `boot_fb`'s bands read ff0000/00ff00/0000ff off the scanout —
  pixels verified by bytes, not self-report. This is the substrate
  `nativeCompositor` and the Hyprland-oracle path both need.
- multiboot2/PVH boot, 32→64 trampoline, COM1 serial, TSC clock
- 8259 PIC + IDT + exception delivery; interrupt-driven virtio-blk
  completion (`hlt` parks on vectors, no burn loops); LAPIC + MSI-X
  for modern devices (vectors 0x30+, EOI to 0xFEE000B0, never the
  PIC; `koru_dev_sleep(kind)` parks a wait on its WaitKind — gpu
  rides the same seam blk does, one extern not N)
- PIT tick preemption: per-child frames + CR3, round-robin roster of ≤4
  ring-3 ELF64 children, in-place ISR-frame rewrite
- `SYSCALL`/`SYSRET` seam with rights bags (NR bitmask today)
- blocking console input: `read(0)` on an empty conin ring parks the
  child `.blocked` (trap frame → full UserFrame, entry-faithful tail);
  IRQ1's `wakeConin` completes the read into the parked buffer, count in
  saved rax. Epoch drains on all-dead (`anyLive`), not all-runnable —
  a parked child holds the roster open
- ext2: mount/create/verify/fetch — **path as projection over inode
  identity** (`dirFind`/`lookupPath`/`lookup`); `exec(path)` folds
  walk→inode→ELF→spawn; `pin`/`exec-nid` run a child *by identity*
- nid: correspondence-row Table (open/resolve/probe/call/retarget) +
  arm-provided object-pin store (`koruos_nid_obj_pin/key` in
  `runtime.zig`)

## Open axes (dependency order)

```
kernel-as-context (LANDED: kblock suspends a trap mid-call on its own
  kstack — conin/blk/exit are wait_kind tags on one primitive; the tick
  is a full scheduling point — schedPreempt saves the CPL3 frame and
  tails into the shared schedLoop/switchInto dispatcher, so a woken
  continuation resumes at the next tick (tick-kctx row measures it);
  open: kernel contexts themselves are non-preemptible while running)
  + FPU state; shell REPL landed (nr57 spawn-on-exit,
  status to rax); argv rides the spawn seam as a NUL-separated blob
  (args.elf evidence: argc/argv vector + status home); pipes-as-seams
  landed (typed fd projection: conin/conout/fs/pipe_r/pipe_w kinds on a
  shared slot table; nr22 pipe mints a refcounted ring, nr58 spawn_start
  wires fd0/fd1 explicitly and leaves a .waitable child whose .zombie
  nr61 wait claims once; .pipe is the fifth wait kind — reader-parks-on-
  empty, EPIPE/EOS on last-end close; pipegen|catc drains 20B through a
  real ring with rwaits counted); fork landed (nr57 = real musl _Fork,
  koru verbs at 512+; eager user-aspace copy, frame synthesized at the
  gate, fds dup per kind with refcounted fs handles; clone refuses
  non-SIGCHLD shapes by name; forktest proves shared fd offset + private
  pages + zombie reaping); general wait
  keys are now mechanical: new kind + a waker mark + a recheck loop
  (frame allocator + reclaim landed: refcounted 4KiB frames, pinned-buffer
   + pair-release shapes proven; bump heap remains for program data)
    → syscall surface + nid-scoped grant bags (LANDED: mask = class
      projection + grants[] object records in the pin keyspace; blob is
      the KGRB section stream; openat is the first object-checked arm)
      → fs.object verbs + nid dispatch (LANDED: obj-stat/obj-read/
        obj-write + nr514 openobj dispatch by pin key; the iface lift
        factors when a second fs provider lands); indirect writes
        LANDED (blkAtAlloc: single+double, triple ENOSPC); dirs open
        → input + display, MSI-X, ACPI — PCI enum + virtio-gpu LANDED
          (pci.zig enumerate-once table; virtiopci.zig modern
          transport + VERSION_1 + MSI-X; gpu.zig 2D chain, screendump-
          verified pixels; GOP/ACPI still open); surfaces-over-fb
          LANDED (surf.zig pool, *Surf<open!>, present = blit +
          commit, screendump-verified rects; cascade placement is
          the named bound — real stacking is the compositor's)
          → init/shell/process userland (fork/exec, pipes/IPC)
            → nativeCompositor + Hyprland/Noctalia oracle harness
```

Also open, smaller:

- ~~pins as Table *rows* (generation/retarget/stale-on-use for object ids),
  pin leasing + eviction~~ — landed: pin rows are the *lease* (`{nid,
  gen, live}`) separate from durable nid identity; remount bumps the
  mount epoch and stales old rows at use, re-pin re-leases the same nid,
  `unpin` evicts; every nid-dispatched verb shares the row check
- ~~rename/unlink/`..`/`.` so "identity survives the view" is provable~~ —
  landed (writable-fs rung): pin→rename→exec-bynid proves identity
  outlives the view; still open: link/mkdir/rmdir
  (single+double indirect write allocation landed — files to ~66 MiB,
  sparse, host debugfs IND/DIND evidence)
- bootable media: GRUB multiboot2 image (link.ld already carries the
  header), init that doesn't halt-on-exit, shutdown/reboot
- SMP (ACPI MADT + IOAPIC + AP bringup) — required before real hardware
- KolibriOS study: first pass done —
  `notes/kolibrios-donor-read.md` (syscall table, VFS seam, devman
  driver model, v86, **GUI/windowing incl. win_map + damage
  protocol**, lift/don't-lift). Deeper reads TBD: `core/v86.inc`
  for the DOS personality

## Not doing (explicit)

- Not embedding Hyprland as the native host — it's the oracle.
- Not making POSIX the primary ontology — it's a view over the
  relational/identity layer.
- Not shipping a fake compositor to claim the milestone early.
- Not importing an LKM stack or a host Linux kernel — compatibility
  comes from personality providers (magic → ABI family), not from
  adopting another kernel's architecture.
