#!/usr/bin/env bash
# stage-foot.sh — vendor a real Debian foot terminal + glibc closure
# onto a boot ext2 image.
#
# Runs inside WSL (check-boot.sh invokes `wsl -e bash <this> ...`):
#   stage-foot.sh <img> <stage> <elfdir> <shpty-bin> [cagedir]
#     <img>       ext2 image path (created)
#     <stage>     dpkg-deb -x extraction root (etc/usr/var)
#     <elfdir>    dir holding footinit.elf + wlserver.elf
#     <shpty-bin> dir holding bin/busybox + lib/ld-musl-x86_64.so.1
#                 (fetch-shpty.sh output)
#     [cagedir]   optional dir holding cage.elf + cageinit.elf —
#                 staged at / for the nested-compositor rung
#
# Why a staged tree walk instead of individual writes: the closure is
# ~1100 files (fontconfig conf.d, terminfo, xkb, gconv). And why
# materialize every symlink as a real file copy: the fs view has no
# symlink layer — a link IS a refusal, so each Debian link becomes a
# second write under the link's own name. Dir-targeted links (xkb ->
# xkeyboard-config-2) get their target tree rewritten under the link
# path.
set -euo pipefail
IMG="${1:?usage: stage-foot.sh <img> <stage> <elfdir> <shpty-bin>}"
STAGE="${2:?}"
ELFDIR="${3:?}"
SHPTY="${4:?}"
CAGEDIR="${5:-}"

/usr/sbin/mke2fs -q -F -t ext2 -b 1024 -I 128 -N 16384 -O none -L koru-foot "$IMG" 131072 >/dev/null

WORK="$(dirname "$IMG")"
# deterministic fixtures: foot's [csd] preferred=none needs no
# server-decoration protocol; /etc/shells is what foot's is_valid_shell
# checks before exporting SHELL to the spawned session's env.
printf '[csd]\npreferred=none\n' > "$WORK/foot.ini"
printf '/shellproof.elf\n/bin/sh\n' > "$WORK/shells"

CMDS="$WORK/debugfs-foot.cmds"
{
    echo 'mkdir bin'; echo 'mkdir lib64'; echo 'mkdir lib'
    echo 'mkdir tmp'; echo 'mkdir root'

    # tree walk — dirs sorted so parents exist before children; file
    # links materialize under their own name; dir links recurse. The
    # walk anchors at "." and keeps only the payload roots: a named
    # root that doesn't exist in this fetch (var comes and goes with
    # the package set) must not error, and find's "." can't ENOENT.
    (cd "$STAGE" && find . -type d | sort) | while read -r d; do
        case "$d" in ./etc*|./usr*|./var*) echo "mkdir ${d#./}";; esac
    done
    (cd "$STAGE" && find . \( -type f -o -type l \) | sort) | while read -r f; do
        case "$f" in ./etc*|./usr*|./var*) ;; *) continue;; esac
        f="${f#./}"
        src="$STAGE/$f"
        tgt=$(readlink -f "$src" 2>/dev/null || true)
        if [ -L "$src" ]; then
            if [ -d "$tgt" ]; then
                # dir-targeted link: rewrite the target tree under the link
                # path. `cd /` first — mkdir resolves against debugfs's cwd,
                # which the file writes move deep into the tree.
                echo 'cd /'; echo "mkdir $f"
                # `|| true` — a target with no subdirs/emptiness makes grep
                # answer 1 and pipefail would abort the whole walk.
                (cd "$tgt" && find . -type d | sed 's|^\./||' | grep -vx '\.' | sort || true) | while read -r sd; do
                    echo 'cd /'; echo "mkdir $f/$sd"
                done
                (cd "$tgt" && find . -type f | sed 's|^\./||' || true) | while read -r sf; do
                    d=$(dirname "$sf"); b=$(basename "$sf")
                    echo "cd /$f/$d"; echo "write $tgt/$sf $b"
                done
                continue
            fi
            [ -f "$tgt" ] || continue # dangling link — refuse honestly
            src="$tgt"
        fi
        d=$(dirname "$f"); b=$(basename "$f")
        echo "cd /$d"; echo "write $src $b"
    done

    # the loader path glibc bakes into PT_INTERP
    echo 'cd /lib64'; echo "write $STAGE/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 ld-linux-x86-64.so.2"
    # foot + compositor + shell payload
    echo 'cd /'; echo "write $ELFDIR/footinit.elf footinit.elf"
    echo "write $ELFDIR/wlserver.elf wlserver.elf"
    echo "write $ELFDIR/shellproof.elf shellproof.elf"
    if [ -n "$CAGEDIR" ]; then
        # nested-compositor rung: upstream cage + its orchestrator
        echo "write $CAGEDIR/cage.elf cage.elf"
        echo "write $CAGEDIR/cageinit.elf cageinit.elf"
    fi
    echo 'cd /bin'; echo "write $SHPTY/bin/busybox busybox"
    echo "write $SHPTY/bin/busybox sh"
    echo 'cd /lib'; echo "write $SHPTY/lib/ld-musl-x86_64.so.1 ld-musl-x86_64.so.1"
    echo "write $SHPTY/lib/ld-musl-x86_64.so.1 libc.musl-x86_64.so.1"
    echo 'mkdir etc/xdg'
    echo 'mkdir etc/xdg/foot'
    echo 'cd /etc/xdg/foot'; echo "write $WORK/foot.ini foot.ini"
    echo 'cd /etc'; echo "write $WORK/shells shells"
} > "$CMDS"

/usr/sbin/debugfs -w -f "$CMDS" "$IMG" >/dev/null 2>&1 || true

# evidence, not trust: stat what the gate will open
for p in /usr/bin/foot /lib64/ld-linux-x86-64.so.2 /bin/sh \
         /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf \
         /usr/share/X11/xkb/keycodes/evdev /etc/fonts/fonts.conf \
         /usr/lib/locale/en_US.utf8/LC_CTYPE \
         /etc/xdg/foot/foot.ini /etc/shells \
         /footinit.elf /wlserver.elf /shellproof.elf \
         ${CAGEDIR:+/cage.elf /cageinit.elf}; do
    /usr/sbin/debugfs -R "stat $p" "$IMG" 2>/dev/null | grep -q "Inode:" || {
        echo "stage-foot: $p missing after write" >&2; exit 1; }
done
