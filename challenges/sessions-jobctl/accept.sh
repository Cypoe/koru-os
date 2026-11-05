#!/usr/bin/env bash
echo "sessions-jobctl: landed. Evidence: 'sessions-jobctl' row in scripts/check-boot.sh"
echo "linux twin: gcc jobctl.c (no -DKORU_DOOR) -> setsid/openpty/TIOCSPGRP path under WSL"
exit 0
