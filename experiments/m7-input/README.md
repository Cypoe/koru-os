# M7a: evdev key input (native i8042 provider, Linux evdev personality)

**Result: PASS 3/3 under TCG, 2026-10-19 13:56–13:57 CEST** (after the freeze commit
`0f5a0e9`, 13:56:36), kernel `/workspace/m7kclean` (clean build from pristine sources,
sha256 `68e7f446…`, 666,288 B). QEMU wall 7.961 / 7.890 / 7.885 s (boot to QMP quit).
Regressions on the same kernel, 14:04–14:08 CEST: M3 3/3, M4 (a)–(d) 3/3, M5a 3/3, M6 3/3
(`evidence/regress-*`). M7b (`libinput debug-events`) is open: B15 (no sysfs/udev).
Criteria: DESIGN-0001 §0.4 "M7a acceptance"; decision: "M7 decision".

## What runs
- **Kernel.** The M6 arm plus `lib/koruinput` (`input_rows.h` rows, `ps2kbd.c` provider,
  `evdev_linux.c` personality) and two patches in `patches/`: devfs poll dispatch +
  `O_NONBLOCK` to device read, and the posix-poll fix for vfscore epoll entries (B14).
- **Device.** The i440fx i8042, translated mode (set 1). IRQ 1 only fills a byte ring; the
  `koru-input` kernel thread decodes and feeds the rows. Aux port (mouse) disabled.
- **Host.** `drive.py` injects keys with QMP `input-send-event`: k o r u shift+1 enter up esc
  for `evdump`, then a b for unmodified Debian `evtest` 1.35, then `quit`.

## Results (each run)
- (i1) `/dev/input/event0` char 13,64. (i2) identity, bitmaps, `EAGAIN`, `EVIOCGRAB`
  0/-EBUSY/0/-EINVAL. (i3) 54/54 evdump events equal the sequence check.py derives from the
  host keys; 18 keys, 18 SYN, 18 `MSC_SCAN`, timestamps monotonic, 18 `poll()` wake-ups.
  (i4) evtest prints the 12 expected events for a and b. (i5) 20 refusal rows, all start-up
  rows already classified in M6 (brk, rseq, set_robust_list, prctl, sysvsem), no evdev
  refusals. (i6) 54 queued, 54 read, 0 dropped, 18 IRQs, 0 ring drops. (x) clean.

## L1 twin (oracle, `run-l1.sh`, 2026-10-19 13:52 CEST)
Debian 6.12.113 with `atkbd` + `evdev.ko`, same binaries and `drive.py`: the same 54 evdump
triples and the same 12 evtest events (check.py on the L1 log: i2, i3 sequence, i4 pass; the
koru-specific lines i1/i6 do not exist there, `evidence/l1/check-on-l1.txt`). Accepted
differences: device name, 145 vs 107 declared key codes, ioctl return values (byte counts on
Linux, 0 on koru-os).

## Findings fixed before the freeze
- B14: `eventpoll_signal()` on a vfscore file crashed (upstream `epf` never set).
- `0xaa` (LeftShift break in set 1) was filtered as a BAT code; shift release was lost.
- `MSC_SCAN` for 0xE0 keys now `code | 0x80`, as `atkbd`.

## Inputs (not committed)
`evtest` from `apt-get download evtest` (GPL-2, used on the box only), glibc from the box,
static busybox from M3, Debian kernel and `evdev.ko` from the M6 L1 inputs.
