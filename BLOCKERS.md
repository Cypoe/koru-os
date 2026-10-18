# Blockers (as of 2026-10-18, Europe/Berlin)

| # | blocker | affects | evidence | needed |
|---|---|---|---|---|
| B1 | KVM unusable: vCPU creation oopses the box kernel (`kvm_spurious_fault` / `vmx_vcpu_create`) | speed of every QEMU milestone; M8–M10 (software GL) in particular | `experiments/m1-blk/evidence/kvm-oops-dmesg-excerpt.txt`, `run-kvm-attempt.txt` | working nested VMX on the box host; until then everything runs on TCG |
| B2 | No ext2/ext4 or FAT driver in the Unikraft 0.21.0 core | M2 (DoD-1) | DESIGN-0001 §0.3 (core library list) | choose: port lwext4 or a small ext2 under vfscore, or the LKL blk/fs silo (DS1) |
| B3 | Newer `boot-animator` state (demo `.anim` files, `/bin/ascii-animator`) is not pushed | M4 (T-CYB) | DESIGN-0001 Q18 | Fabian pushes it; until then a labelled stand-in is used |
| B4 | The box has no GitHub write credential (`gh auth status`: not logged in) and the connector has no file-write tool | pushing this repository | see `PUSH.md` outside the repo | a push by someone with write access to `Cypoe/koru-os`, or a credential on the box |
