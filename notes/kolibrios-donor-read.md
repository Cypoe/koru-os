# KolibriOS donor read — first pass

Pinned: `upstream/kolibrios` @ `45b134ba` (vand ledger entry `kolibrios`).
Purpose: extract architecture for koru-os; lift shapes and decisions,
not code — the tree is 32-bit flat assembler.

## 1. Syscall surface — `kernel/trunk/core/syscall.inc`

`servetable2`: flat `dd` table, indexed by syscall number, dual-entered
via `SYSENTER` (`sysenter_entry`) and `int 0x40` (`i40`). ~75 defined
entries, `undefined_syscall` fills the rest, `-1` = `sys_end`
(application exit). Notable for the future `koruos/kolibri`
personality arm — the table IS the personality spec:

- `2 GetKey`, `5 DelayHs`, `9 GetProcessInfo` — classic UI/scheduler
- `18 System Services` — umbrella subfunction space
- `23 TimeOutWaitForEvent`, `10/11 Wait/CheckForEvent` — event model
- `46 ReservePortArea` — **I/O port space is a first-class syscall**
- `60 sys_IPC` — message IPC exists
- `61 sys_gs` — "direct graphics access"
- `63 sys_msg_board` — kernel message board (debug/crash board)
- `64 Resize application memory` — single-heap grow model, no mmap
- `70 sys_file_system_lfn` — THE fs seam (see §2); subfn 7 = `fs_execute`
  — **exec goes through the fs seam, same as `ext2:exec`**
- `74-76 network/socket/protocols` — socket layer as sysfns
- `77 sys_posix` — posix support exists as its own number
- `80 fileSystemUnicode` — encoding-aware variant of 70

Dispatch mechanics worth noting: `protect_from_terminate` wraps every
call — a dead/stale task can't take kernel state down mid-syscall.
Return values go back through *images on the stack* (`image_of_eax`)
so the `popad`/`iretd` tail restores user regs with results patched
in — the same trick koru's `irq_exc_common` frame-rewrite uses for
preemption.

## 2. VFS seam — `fs/fs_lfn.inc`, `blkdev/disk.inc`, `fs/ext.inc`

Three-layer stack, cleanly separated:

```
sysfn70 (param struct in ebx, subfn in [ebx])        user ABI
  └─ file_system_lfn: getFullPath → partition → FS vtable   VFS layer
       └─ PARTITION.FSUserFunctions → ext_user_functions    fs driver
            └─ DISK.Functions (DISKFUNC) → driver           block layer
```

- **`DISKFUNC`** (`disk.inc:36`): block-driver vtable —
  `close, closemedia, querymedia, read, write, flush,
  adjust_cache_size, LoadTray`, preceded by `strucsize` for
  forward-compatible extension. `disk_call_driver` checks
  `offset < strucsize` and slot non-NULL, else falls to
  `disk_default_callbacks` — **capability-optional provider dispatch
  with named refusal** (`DISK_STATUS_INVALID_CALL`), not a silent
  success. This is the exact pattern `koruos.blk.*` would want.

- **Media lifecycle** (`disk_media_changed`): driver calls up on
  media change → kernel `querymedia` → allocate cache →
  `disk_scan_partitions` → each `PARTITION` starts with
  `default_fs_functions` → refcounted (`DISK.RefCount`,
  `MediaRefCount`) so open handles survive media-yank.

- **fs registration is probe-claim, not mount table**
  (`fs_add`): an fs driver registers `create_partition` +
  `UserFuncs` + name globally; the kernel walks `disk_list` ×
  partitions and lets each registered fs *probe* unclaimed
  partitions; a successful probe swaps `default_fs_functions` for
  the driver's vtable. Contrast with koru's explicit `mount`:
  Kolibri trades explicitness for plug-in ergonomics. koru should
  keep explicit mount (identity wants a named mount point anyway)
  but the probe function shape is worth keeping as
  `fs.probe(partition) → functions | refuse`.

- **`ext_user_functions`** — the per-fs vtable has FOURTEEN slots:
  `free, ReadFile, ReadFolder, CreateFile, WriteFile, SetFileEnd,
  GetFileInfo, SetFileInfo, <pad>, Delete, CreateFolder, Rename,
  CreateSymlink, ReadSymlink`. Kolibri's `ext.inc` (ext2/3/4)
  already does WriteFile/Rename/symlinks — the same donor can
  serve as the semantic reference for finishing koru ext2.

- Errors are a flat numbered space (`ERROR_FILE_NOT_FOUND=5`,
  `ERROR_UNSUPPORTED_FS=2`, `ERROR_ACCESS_DENIED=10`...) — one
  axis, named. Matches the refusal-by-name convention.

## 3. Driver model — `drivers/`, `kernel/trunk/core/exports.inc`

- Drivers are **loadable PE modules** (`core/peload.inc` is the PE
  loader in-kernel) linking against the kernel's export table:
  `exports.inc` lines like `reg_service, 'RegService'`, `AllocPage`,
  `GetTimerTicks`, `GetClockNs`, `UserAlloc/UserFree`... — a flat
  C-ABI service table, symbol-name keyed.
- A driver registers a **named service** — `RegService(name,
  srv_proc_t)` — and userspace/other drivers invoke it by name.
  Service names are the capability seam: getting e.g. "DISPLAY"
  requires the name, and absence fails loudly.
- **`drivers/devman/`** is the device manager: ACPI (imported
  ACPICA) + PCI scan (`pci/probe.c`, `pci_bind.c`) → `dmdev_t`
  device list → driver binding. The bus-discovery half of the
  driver story lives outside the drivers.
- **`drivers/ddk/linux/`** — Linux kernel *helpers* ported into the
  DDK (`rbtree, workqueue, kref, idr, scatterlist, dmapool, mutex,
  interval_tree, hdmi.c, msr.c`...) so Linux driver C compiles
  against Kolibri's kernel services. **This is the adapter-arm
  pattern in the wild**: Kolibri didn't adopt Linux's driver model;
  it kept its own service-registry model and provided enough
  linux-flavored substrate that foreign driver code compiles
  unchanged. That's the honest precedent for option (b) in the
  `uk_*`-vs-`koruos.*` question — own the contract, shim the donor.
- `hid/` — keyboard/mouse live *inside* the kernel tree
  (`kernel/trunk/hid/`), not as devman drivers — a reminder that
  "driver" vs "core" is a judgment call even in Kolibri; input and
  the GUI event pump are fused to the kernel.

## 4. v86 — `core/v86.inc`

`v86_create` → `V86_machine` handle: `process` (owning task),
`mutex`, `iopm` (I/O permission map). Real vm86 machines with
per-instance I/O permission bitmaps — the working reference for the
DOS personality filed in PLAN.md. A koru DOS personality = v86
machine + `int 21h` family over koru providers; Kolibri's is the
same shape with its own syscall table underneath.

## 5. GUI / windowing — `gui/`, `hid/`, `const.inc`

The compositing model is shockingly simple and worth understanding
whole before designing `nativeCompositor`:

- **`_display.win_map` — per-pixel ownership.** A byte map the size
  of the framebuffer; each pixel holds the *slot number* of the
  window that owns it. Drawing primitives clip by testing
  `win_map[px] == my_slot`. There is no compositor, no blending, no
  alpha — z-order + damage + an owner map. Recalculated on
  z-change/move/resize; `calculatebackground` fills it with the
  desktop's id when the background changes.

- **`WDATA` — the window record is 128 bytes** (`const.inc:630`,
  size asserted). box (geometry), `clientbox`, three packed
  color/style dwords, `fl_wstate/fl_wdrawn/fl_redraw` flags,
  `shape`+`shape_scale` (arbitrary shaped windows exist!),
  caption+encoding, `saved_box` (maximize restore), per-window
  `cursor`/`temp_cursor`, **`draw_data RECT` = the damage region**,
  `thread → APPDATA`, buttons array. Everything a minimal
  compositor needs is in one cacheline-pair.

- **Damage protocol** — kernel sets `WDATA.fl_redraw` and fills
  `draw_data` with the invalid rect; app sees event bit 0 in
  `occurred_events`; `BeginDraw`/`EndDraw` (sysfn 12) is the
  bracket that makes draws legal and resets the flag. The app
  repaints *into the shared framebuffer*, clipped by win_map — the
  kernel owns the pixels, apps borrow them.

- **Event model is bitmask-word, not queue.** `APPDATA.event_mask`
  (registered via sysfn 40) + `APPDATA.occurred_events`;
  `get_event_for_app` `bsr`-scans the mask in priority order:
  bit0→redraw(checks fl_redraw), bit1→key, bit2→button, bit4→
  background, bit5→mouse, 6-9→IPC/stack/debug. Payloads fetched by
  separate sysfns (`GetKey` reads `KEY_BUFF`, `GetButton` →
  `BTN_BUFF`). `Wait_events_ex` is the general wait loop — a
  client-supplied test function + timeout, and it's exactly the
  wait-queue shape koru's blocking-children work needs.

- **Focus = stack-top.** `WIN_STACK` is a u16 array of slot ids in
  z-order; `thread_count` is the top index; keys/buttons only
  deliver to top (`cmp edx, [thread_count]`). `KEY_BUFF`/`BTN_BUFF`
  are small global rings (120 keys, overflow drops). Mouse events
  carry `EVM_MOUSE_FILTER`; suppressed while the user
  drags/resizes a window (`WINDOW_MOVE_AND_RESIZE_FLAGS`).
  `hotkey_buffer` gives global hotkeys per slot — checked after
  normal keys. Button id `0xFFFF` is minimize → `wakeup_osloop`.

- **Kernel objects are a real object model.** `APPOBJ` header on
  `CURSOR`/`EVENT`/`SMEM`: `magic`, `destroy` (internal destructor),
  fd/bk links, `pid` owner — on process death the object lists are
  walked by pid and destroyed. Same pattern the EVENT layer uses.
  This is the closest thing in the tree to koru's "provider object
  owned by a nid, cleaned on exit" semantics.

- **Input is fused to the kernel.** `hid/keyboard.inc` +
  `hid/mousedrv.inc` feed `KEY_BUFF`/`mouse` state directly; GUI
  `mouse.inc` owns cursor compositing. Input→event has no
  indirection — there's no "input provider" seam to speak of.

### What this means for `nativeCompositor`

The Kolibri model is honest but it's a *pixel-ownership* design —
single framebuffer, opaque rects, damage-by-rect, no per-window
surfaces. koru's direction should keep the semantics (z-order,
damage rects, focus stack, event bits) but invert the mechanism:
windows get *surface objects* (nid-pinned), the compositor owns
win_map-equivalent hit-testing, drawing goes through the compositor
not directly to the framebuffer. Kolibri's win_map is then the
semantic oracle for hit-test/damage correctness — "same pixel goes
to the same window" is a testable equivalence even if the mechanism
is a scene graph. The BeginDraw/EndDraw bracket and the
redraw-bit+draw_data damage protocol are both worth keeping
almost verbatim.

Also worth the same note: `Wait_events_ex` (test-fn + timeout) is
the right shape for koru's wait queues, and `APPOBJ.magic +
destroy + pid` is the shape for provider-object lifetime
auditing — kill-process walks owned objects and calls destructors,
which is what "nid bindings released on exit" wants mechanically.

## Lift / don't lift

| lift (as concepts) | don't lift |
|---|---|
| `strucsize`-bounded vtables + named-default dispatch (capability-optional providers) | flat 32-bit asm; global `fs_list`/`disk_list` state with `cli`/`sti` locking (marked `; DELETE` in-tree — they know it's wrong) |
| `RegService` named-service registry — service-name-as-capability | PE driver modules / peload — koru wants nid-bound providers, not imported PE exports |
| probe-claim `fs.probe()` shape | probe-claim *binding* — koru keeps explicit mount; identity needs named mounts |
| v86 monitor + iopm for the DOS personality | sysfn70's packed-param-struct ABI — koru's typed seams, not a dword bag |
| `ddk/linux` shim precedent for the ABI question | `sys_posix` as bolt-on syscall number — POSIX is a view, not a syscall |
| win_map per-pixel ownership → compositor hit-test oracle; fl_redraw+draw_data damage protocol; BeginDraw/EndDraw bracket; bitmask event words + Wait_events_ex | GUI-in-kernel + paint-direct-to-framebuffer: koru wants surface objects and the compositor owning pixels, not apps borrowing them |
| media lifecycle (querymedia→cache→scan→probe→refcount) | single address space per app with one growable heap (sysfn 64) |

## The one-line summary for koru-os

KolibriOS proves a small OS can run the exact seams koru is
designing — table-dispatched syscalls, vtable-bound providers,
named-service capabilities, fs-as-provider-behind-one-number —
at ~one order of magnitude less code than Linux. Its value is
*semantic*: the shapes are all here, small enough to read whole.
