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

## Landed (koru-native arm, gated by `scripts/check-boot.sh` — 16/16)

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
frame allocator + page reclaim + teardown        (heap is a 4MiB bump; free is a no-op)
  → wait queues + kernel-as-context + per-task kstacks + FPU state
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
  driver model, v86, lift/don't-lift). Deeper reads TBD:
  `gui/event.inc` + `hid/` for nativeCompositor, `core/v86.inc` for
  the DOS personality

## Not doing (explicit)

- Not embedding Hyprland as the native host — it's the oracle.
- Not making POSIX the primary ontology — it's a view over the
  relational/identity layer.
- Not shipping a fake compositor to claim the milestone early.
- Not importing an LKM stack or a host Linux kernel — compatibility
  comes from personality providers (magic → ABI family), not from
  adopting another kernel's architecture.
