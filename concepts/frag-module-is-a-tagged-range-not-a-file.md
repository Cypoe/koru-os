---
type: belief
id: frag-module-is-a-tagged-range-not-a-file
provenance: koru-os native session — mb2 module rung, 2026-11
ts: 2026-11-01
tags: [native, boot, multiboot2, grub, loader, module]
---

**A loader module is a tagged physical range plus a cmdline — the
file it came from is not part of the contract.** mb2 tag 3 hands the
kernel `{start, end, string}` per module: absolute phys addresses,
one tag per file, payload outside the tag. pmm parses the tags,
`reserve()`s every payload page (loader memory is never allocatable
RAM), and `koruos/module` execs the bytes through rung-2 spawn with
`fsv=null` — a module child gets ENOSYS on open, honestly, because a
module is bytes, not a filesystem. The initramfs provider is the rung
that turns those same bytes into a `ChildFsOps` view.

Two loader facts cost real debugging time — record them so they
never cost it again:

- **`module` is multiboot(1); `module2` is multiboot(2).** GRUB split
  the commands when it disentangled the two loaders — `module` checks
  mb1's relocator and refuses "you need to load the kernel first"
  under mb2 no matter the ordering. There is no ordering that fixes
  it; the command name is the fix.
- **The tag's string is a cmdline, not the path.** `module2 FILE`
  with no args records an EMPTY name — the file's own path never
  reaches the kernel. `module2 FILE NAME...` makes the args the
  module string (the spec's intended "arguments to modules" shape).
  Pass the basename explicitly or the kernel sees `""`.

Held consequence — the transport is loader-agnostic by construction:
any mb2 loader that emits tag 3 (GRUB `module2`, QEMU `-initrd` under
a multiboot2 kernel, Limine's MODULE_PATH) feeds the same pmm table.
What each loader does differently is only *how the bytes got there*.
