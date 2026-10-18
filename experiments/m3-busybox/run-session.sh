#!/usr/bin/env bash
# Scripted interactive serial session: hush reads commands from the serial line (COM1).
HERE=$(cd "$(dirname "$0")" && pwd)
(sleep 3; for c in 'echo M3-HELLO' 'uname -a' 'echo $((6*7))' 'echo koru > /tmp/f; cat /tmp/f' 'mkdir /tmp/d && echo mkdir-ok' 'id' 'sha256sum /bin/busybox' 'echo x | cat' ; do
  printf '%s\n' "$c"; sleep 1.5; done; sleep 2) | "$HERE/qemu.sh" "/bin/busybox sh" 2>&1 | tr -d '\r' | sed -n '/Powered by/,$p'
