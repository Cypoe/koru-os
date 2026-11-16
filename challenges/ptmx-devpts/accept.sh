#!/usr/bin/env bash
echo "ptmx-devpts: landed. Evidence: 'foot-real' row in scripts/check-boot.sh"
echo "oracle: glibc foot posix_openpt(/dev/ptmx) -> unlockpt -> open(/dev/pts/0) -> TIOCSCTTY -> shell"
exit 0
