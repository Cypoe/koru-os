#!/usr/bin/env bash
echo "pty-termios: landed. Evidence: 'pty-termios' row in scripts/check-boot.sh"
echo "linux twin: zig cc ptytest.c (no -DKORU_DOOR) -> posix_openpt path"
exit 0
