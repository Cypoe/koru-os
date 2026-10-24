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
compositor's own account, not ours. `koru-native` refuses by name
until `nativeCompositor` or a surface-over-fb family exists.

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

## Landed (koru-native arm, gated by `scripts/check-boot.sh` — 21/21)

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
- **`koruos/fb` — first visual output.** `koru/fb/index.kz` lift
  (info/fill/px over a linear framebuffer, `absent` refusal) +
  `koru/native/fb.zig` provider. Two honest sources, tried in order:
  mb2 mbi tag 8 (GRUB programs the mode), else **BGA** — QEMU's
  `-kernel` multiboot loader does not answer the fb request tag, so
  the provider programs the std VGA's `VBE_DISPI` registers
  (0x1CE/0x1CF) itself and takes the LFB phys from PCI BAR0 (class-03
  scan). The fb range is identity-mapped on demand in a second pd
  (`pd_hi`, one 1 GiB window — a second window needs the frame
  allocator's page-table story; deliberately not it). Verified by
  QEMU screendump: `boot_fb` paints red/green/blue bands and the
  gate asserts geometry on serial (17/17). This is the substrate
  `nativeCompositor` and the Hyprland-oracle path both need.
- multiboot2/PVH boot, 32→64 trampoline, COM1 serial, TSC clock
- 8259 PIC + IDT + exception delivery; interrupt-driven virtio-blk
  completion (`hlt` parks on vectors, no burn loops)
- PIT tick preemption: per-child frames + CR3, round-robin roster of ≤4
  ring-3 ELF64 children, in-place ISR-frame rewrite
- `SYSCALL`/`SYSRET` seam with rights bags (NR bitmask today)
- ext2: mount/create/verify/fetch — **path as projection over inode
  identity** (`dirFind`/`lookupPath`/`lookup`); `exec(path)` folds
  walk→inode→ELF→spawn; `pin`/`exec-nid` run a child *by identity*
- nid: correspondence-row Table (open/resolve/probe/call/retarget) +
  arm-provided object-pin store (`koruos_nid_obj_pin/key` in
  `runtime.zig`)

## Open axes (dependency order)

```
wait queues + kernel-as-context + per-task kstacks + FPU state
  (frame allocator + reclaim landed: refcounted 4KiB frames, pinned-buffer
   + pair-release shapes proven; bump heap remains for program data)
    → syscall surface + nid-scoped grant bags (replaces NR bitmask)
      → fs.object iface + nid dispatch; fs writes/dirs/indirects
        → input + display (virtio-gpu | GOP), PCI enum + MSI-X, ACPI
          → init/shell/process userland (fork/exec, pipes/IPC)
            → nativeCompositor + Hyprland/Noctalia oracle harness
```

Also open, smaller:

- pins as Table *rows* (generation/retarget/stale-on-use for object ids),
  pin leasing + eviction
- `exec(nid)` resolving the provider from the pin itself (no caller-held fs)
- rename/unlink/link/`..`/`.` so "identity survives the view" is provable
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
