# Blockers (as of 2026-10-18, Europe/Berlin)

| # | blocker | status | affects | evidence | needed |
|---|---|---|---|---|---|
| B1 | **KVM unusable.** `/dev/kvm` is rw for the box user (`crw-rw-rw-`), but vCPU creation oopses the host kernel (`kvm_spurious_fault` in `vmx_vcpu_create`, 6.12.94+). The oops was already in the log before this work | open; KVM is **not** to be touched again; TCG only | speed of every QEMU milestone, M8–M10 most | `experiments/m1-blk/evidence/kvm-oops-dmesg-excerpt.txt`, `run-kvm-attempt.txt` | working nested VMX on the box host |
| B2 | No ext2/ext4 or FAT in the Unikraft 0.21.0 core; no `lib-lwext4` reachable; upstream lwext4 is GPL-2.0; `lib-fatfs` is empty | **worked around for M2** with the minimal ext2 Koru lift (`koru/ext2`) | M2 done in narrow scope; M3+ needs vfscore integration or a fuller FS | `experiments/m2-ext2/README.md` | vfscore glue for `koru/ext2`, or a licence-compatible full FS |
| B3 | Newer `boot-animator` state (demo `.anim` files, `/bin/ascii-animator`) is not pushed | open; stand-in allowed | M4 (T-CYB) | DESIGN-0001 Q18 | Fabian pushes it |
| B4 | The box has no GitHub write credential and the connector has no file-write tool | open; waiting for `GH_TOKEN` | pushing this repository | `/workspace/koru-os-push/PUSH-INSTRUCTIONS.md` (outside the repo) | token in the environment |
| B5 | `koruc` auto-discharges an obligation that has exactly one disposal, so "leak" programs compile; the inserted `release` came after `close` in one test | finding, not a blocker | DS0 gate design | `experiments/ds0-silo/README.md` | to make leaks hard errors, give a state two disposals (the `blk` pattern); report the ordering to korulang if confirmed |
