# Challenge catalog

The slot board — gaps recorded as challenges. Read first; entries are the
source of truth. `scripts/board.sh` regenerates this table from
`challenges/*/entry.md` frontmatter and `--check` verifies freshness.

States: `landed | open | claimed | waived` ·
Lanes: `native-zig | koru-lift | donor-c | hosted | oracle` ·
Tiers: `qemu | hw` · Evidence: `V | M | C | D`

```
 slot              │iface              │arms               │lane      │needs                      │tier│status    │evidence 
───────────────────┼───────────────────┼───────────────────┼──────────┼───────────────────────────┼────┼──────────┼─────────
 acpi-s3           │koruos/power.s3    │koru-native        │native-zig│[]                         │qemu│open      │—        
 audio-hda         │koruos/audio.pcm   │koru-native        │native-zig│[pci-enumeration]          │qemu│open      │—        
 blk-nvme          │koruos/blk.nvme    │koru-native        │native-zig│[pci-enumeration, irq-msix]│qemu│open      │—        
 busybox-sh-pty    │koruos/oracle.shell│koru-native        │oracle    │[sessions-jobctl]          │qemu│open      │—        
 drm-virtio-gpu    │koruos/kms.drm     │koru-native        │native-zig│[virtio-pci-modern]        │qemu│open      │—        
 fs-initramfs      │koruos/fs.initramfs│koru-native        │koru-lift │[module-transport]         │qemu│**landed**│M        
 glibc-shim        │koruos/abi.libc    │koru-native        │koru-lift │[]                         │qemu│waived    │—        
 gpu-virgl-3d      │koruos/kms.gpu3d   │koru-native        │native-zig│[drm-virtio-gpu]           │qemu│open      │—        
 hw-tier-validation│koruos/oracle.hw   │koru-native        │oracle    │[usb-xhci, usb-hid]        │hw  │open      │—        
 irq-msix          │koruos/irq         │koru-native        │native-zig│[pci-enumeration]          │qemu│**landed**│M        
 module-transport  │koruos/module      │koru-native        │native-zig│[]                         │qemu│**landed**│M        
 net-virtio        │koruos/net.stack   │koru-native        │native-zig│[virtio-pci-modern]        │qemu│open      │—        
 pci-enumeration   │koruos/pci         │koru-native        │native-zig│[]                         │qemu│**landed**│M        
 ptmx-devpts       │koruos/dev.pts     │koru-native        │native-zig│[pty-termios]              │qemu│open      │—        
 pty-termios       │koruos/chan.pty    │koru-native        │native-zig│[]                         │qemu│**landed**│M        
 readdir-verb      │koruos/fs.readdir  │koru-native, hosted│koru-lift │[]                         │qemu│open      │—        
 sessions-jobctl   │koruos/proc.session│koru-native        │native-zig│[pty-termios]              │qemu│**landed**│V        
 smp-multirunner   │koruos/sched.smp   │koru-native        │native-zig│[]                         │qemu│open      │—        
 usb-esp-boot      │koruos/boot.esp    │koru-native        │oracle    │[fs-initramfs]             │qemu│**landed**│M        
 usb-hid           │koruos/input.usb   │koru-native        │native-zig│[usb-xhci]                 │qemu│open      │—        
 usb-storage       │koruos/blk.usb     │koru-native        │native-zig│[usb-xhci]                 │qemu│open      │—        
 usb-xhci          │koruos/usb.host    │koru-native        │native-zig│[pci-enumeration, irq-msix]│qemu│open      │—        
 virtio-pci-modern │koruos/virtio.pci  │koru-native        │native-zig│[pci-enumeration]          │qemu│open      │—        
 vt-engine         │koruos/term.vt     │koru-native, hosted│donor-c   │[pty-termios]              │qemu│open      │—        
```

`accept.sh` per slot is the minimal runnable probe: landed slots re-run
their evidence; open slots print the falsifiable criteria and exit 77
(skip) until the rung lands.
