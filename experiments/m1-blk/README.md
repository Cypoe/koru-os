# M1: sector read/write through koru-libs `unikraft/blk` on virtio-blk

**Result: PASS under TCG (M), three runs, 2026-10-18 about 19:37 CEST. KVM: blocked (box kernel oops).**

## What runs
`koru-libs/unikraft/blk/tests/boot_lifecycle.k` @ `ff5cb559` drives the whole `ukblkdev` ratchet from Koru:

```
get → configure → queue.open → start → read s0 → write s1 → flush → read s1 → stop → queue.close → release
```

It runs inside a Koru-built Unikraft 0.21.0 image against a real QEMU `virtio-blk-pci` disk.

## Acceptance (DESIGN-0001 §0.4, M1)
`run.sh` builds a 64-sector disk with a known sector 0, boots the image and then checks the
result on the host with `cmp`:
- sector 0 is unchanged;
- sector 1 equals the 512-byte payload taken from the `.k` source;
- sectors 2–63 are still zero;
- the serial log contains `lifecycle complete`.

## Measured (M)
| | value | evidence |
|---|---:|---|
| bootable image `koru_qemu-x86_64` | 194,176 B | `evidence/sizes.txt` |
| Koru static archive `libkoruapp.a` | 20,952 B | `evidence/sizes.txt` |
| `kraft build` from a fresh copy | 13 s wall (Unikraft sources already in the kraftkit cache) | `evidence/kraft-build.log` |
| QEMU wall time, launch to exit, including SeaBIOS/iPXE (TCG) | 0.258 s / 0.240 s / 0.260 s | `evidence/run-tcg-*.txt` |
| host `cmp` s0 / s1 / s2–63 | equal / equal / equal, 3 of 3 runs | `evidence/run-tcg-*.txt` |
| negative programs | 4 of 4 rejected by `koruc` with KORU030 (phantom obligation or state mismatch) | `evidence/negatives-koruc.log` |

These numbers differ from the koru-libs README (C: macOS/arm64). The README's
164,544 B figure is for the `hello` image, not this one.

## KVM blocker
`-accel kvm` produced no serial output and was killed by the 60 s timeout. The box kernel
logs an oops in `kvm_spurious_fault` from `vmx_vcpu_create`, and the same oops appears
earlier in the log, before this work started (`evidence/kvm-oops-dmesg-excerpt.txt`). This
looks like nested virtualisation that does not work on this host. `/dev/kvm` opens, but no
vCPU can be created. All results here are TCG. KVM was not retried, to avoid more host
oopses.

## Reproduce
See `evidence/toolchain.txt` for exact versions. The steps are those of the koru-libs
`unikraft/blk` README, plus `run.sh <kernel> <boot_lifecycle.k> <outdir> tcg`.
