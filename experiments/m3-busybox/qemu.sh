#!/usr/bin/env bash
# TCG only (B1). Usage: qemu.sh "<kernel cmdline>"
K=${K:-/workspace/m3img/.unikraft/build/m3-busybox_qemu-x86_64}
exec timeout 40 qemu-system-x86_64 -accel tcg -cpu qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm \
  -m 256M -nographic -no-reboot -display none -parallel none -kernel "$K" -append "$1"
