#!/usr/bin/env bash
# stage-dynamic.sh — vendor a real dynamic userspace into the boot ext2.
#
# Runs inside WSL (check-boot.sh invokes `wsl -e bash <this> $IMGWSL`):
# fetches alpine v3.22 apks into a cache beside the image, extracts the
# ELF payload, and writes /lib (ld-musl + the lib closure) and /bin
# (busybox, GNU coreutils) through debugfs.
#
# Why alpine musl: ld-musl is a real distro dynamic loader and busybox
# is a real distro PT_INTERP binary — dynamic linking is exercised by a
# foreign toolchain's artifacts, not anything we authored. GNU coreutils
# drags a five-library DT_NEEDED closure, proving multi-lib resolution.
set -euo pipefail
IMG="${1:?usage: stage-dynamic.sh <ext2 image path> [hi.elf] [libhi.so]}"
HI="${2:-}"      # zig-built dynamic hello needing liblibhi.so + libc.so
HILIB="${3:-}"   # the .so it needs (zig names it liblibhi.so)
ALPINE="https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64"
WORK="$(dirname "$IMG")/apk-cache"
mkdir -p "$WORK/x"
cd "$WORK"

IDX="$WORK/APKINDEX"
if [ ! -f "$IDX" ]; then
    curl -sSL "$ALPINE/APKINDEX.tar.gz" | tar xzO APKINDEX > "$IDX"
fi

fetch() { # fetch <apk name> — resolves the current version, caches, extracts
    local p="$1" v
    v="$(grep -A4 "^P:$p\$" "$IDX" | grep -m1 "^V:" | cut -d: -f2)"
    [ -n "$v" ] || { echo "stage-dynamic: no $p in index" >&2; return 1; }
    [ -f "$p-$v.apk" ] || curl -sSL "$ALPINE/$p-$v.apk" -o "$p-$v.apk" || return 1
    tar xzf "$p-$v.apk" -C x 2>/dev/null || true
}

for p in musl busybox coreutils libcrypto3 libattr acl-libs utmps-libs skalibs-libs; do
    fetch "$p"
done

# ld-musl serves two names: it is the interpreter AND musl's libc.
CMDS="$WORK/debugfs-dynamic.cmds"
cat > "$CMDS" <<EOF
mkdir lib
cd lib
write $WORK/x/lib/ld-musl-x86_64.so.1 ld-musl-x86_64.so.1
write $WORK/x/lib/ld-musl-x86_64.so.1 libc.musl-x86_64.so.1
write $WORK/x/lib/ld-musl-x86_64.so.1 libc.so
write $WORK/x/usr/lib/libcrypto.so.3 libcrypto.so.3
write $WORK/x/usr/lib/libattr.so.1 libattr.so.1
write $WORK/x/usr/lib/libacl.so.1 libacl.so.1
write $WORK/x/usr/lib/libutmps.so.0.1 libutmps.so.0.1
write $WORK/x/usr/lib/libskarnet.so.2.14 libskarnet.so.2.14
cd /bin
write $WORK/x/bin/busybox busybox
write $WORK/x/bin/uname uname
write $WORK/x/bin/cat cat
EOF
# the two-lib discriminating pair: a zig-built hello + its own .so —
# proves openat+mmap-file+reloc across a NON-self library boundary
if [ -n "$HI" ] && [ -n "$HILIB" ]; then
    printf 'cd /lib\nwrite %s liblibhi.so\ncd /bin\nwrite %s hi.elf\n' "$HILIB" "$HI" >> "$CMDS"
fi

/usr/sbin/debugfs -w -f "$CMDS" "$IMG" >/dev/null
for n in busybox uname cat; do
    /usr/sbin/debugfs -R "stat /bin/$n" "$IMG" 2>/dev/null | grep -q "Inode:" || {
        echo "stage-dynamic: /bin/$n missing after write" >&2; exit 1; }
done
/usr/sbin/debugfs -R "stat /lib/ld-musl-x86_64.so.1" "$IMG" 2>/dev/null | grep -q "Inode:" || {
    echo "stage-dynamic: ld-musl missing after write" >&2; exit 1; }
