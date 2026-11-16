#!/usr/bin/env bash
# fetch-foot.sh — vendor the Debian forky closure the foot rung stages:
# foot itself + the glibc/fontconfig/freetype/harfbuzz/fcft/wayland
# dependency set + fonts-dejavu + xkb/terminfo data + the en_US.utf8
# locale (locales-all is pruned to just that locale — the full package
# is ~240MB and overflows the image).
#
# Runs inside WSL (check-boot.sh invokes `wsl bash <this> <outdir>`):
# writes <outdir>/stage = a dpkg-deb -x tree (etc/usr/var) that
# stage-foot.sh walks onto the ext2 image.
#
# Fetch uses `trusted=yes` — this is an offline test fixture, not a
# system install; the Packages.xz checksum path is documented apt flow.
set -euo pipefail
OUT="${1:?usage: fetch-foot.sh <outdir>}"
STAGE="$OUT/stage"
WORK="$OUT/fetch"
LIST="$WORK/lists"
CACHE="$WORK/cache"
mkdir -p "$STAGE" "$LIST/partial" "$CACHE/archives/partial"

cat > "$WORK/sources.list" <<'EOF'
deb [trusted=yes] http://deb.debian.org/debian forky main
EOF

APT=(
    apt-get
    -o "Dir::Etc::sourcelist=$WORK/sources.list"
    -o "Dir::Etc::sourceparts=-"
    -o "Dir::State::lists=$LIST"
    -o "Dir::Cache=$CACHE"
    -o "APT::Get::List-Changes=0"
)

# foot's runtime closure — the names the ELF's DT_NEEDED plus the
# data packages its startup actually opens (fontconfig conf.d + fonts,
# xkb keymaps, terminfo, gconv, the utf8 locale foot's bad_locale gate
# demands).
PKGS=(
    foot
    libc6 libgcc-s1 libstdc++6 libatomic1
    libfontconfig1 fontconfig-config fonts-dejavu-core fonts-dejavu-mono
    libfcft4t64 libfreetype6 libharfbuzz0b libutf8proc3 libpixman-1-0
    libwayland-client0 libwayland-cursor0
    libxkbcommon0 xkb-data
    libpng16-16t64 zlib1g libexpat1 libbz2-1.0 libbrotli1 libmd0
    libgraphite2-3 libglib2.0-0t64 libpcre2-8-0
    libbsd0 libffi8 libxau6 libxdmcp6
    ncurses-base ncurses-term
    locales-all
)

if [ ! -f "$LIST/lock" ]; then
    "${APT[@]}" update
    touch "$LIST/lock"
fi

cd "$CACHE/archives"
# `apt-get download` per package: the host's installed-state can't
# shrink the closure — every named deb lands here regardless.
for p in "${PKGS[@]}"; do
    apt-get -o "Dir::Etc::sourcelist=$WORK/sources.list" \
            -o "Dir::Etc::sourceparts=-" \
            -o "Dir::State::lists=$LIST" \
            download "$p"
done
find "$STAGE" -mindepth 1 -delete 2>/dev/null || true
for d in ./*.deb; do
    dpkg-deb -x "$d" "$STAGE"
done

# honest closure: every DT_NEEDED of the staged ELF must resolve inside
# the stage — an unsatisfied name prints and fails the fetch.
missing=0
for so in $(readelf -d "$STAGE/usr/bin/foot" | sed -n 's/.*\[\(.*\)\]/\1/p'); do
    case "$so" in linux-*|ld-linux*) continue;; esac
    # whole-stage scan — DrvFs metadata can lag the bulk extract by a
    # beat, so the name check must not depend on the file's exact home.
    if ! find "$STAGE" -name "$so" -print -quit 2>/dev/null | grep -q .; then
        echo "fetch-foot: unresolved DT_NEEDED $so" >&2; missing=1
    fi
done
[ "$missing" = 0 ] || exit 1

# locales-all is ~240MB installed — the rung needs exactly one utf8
# locale. foot calls setlocale(LC_ALL, "") and its C.UTF-8 fallback;
# the en_US.utf8 files are the answer either env can name.
keep="$STAGE/usr/lib/locale/en_US.utf8"
mkdir -p "$WORK/en_US.utf8"
cp -aL "$keep/." "$WORK/en_US.utf8/" 2>/dev/null || true
rm -rf "$STAGE/usr/lib/locale"
mkdir -p "$STAGE/usr/lib/locale/en_US.utf8"
cp -a "$WORK/en_US.utf8/." "$STAGE/usr/lib/locale/en_US.utf8/"

echo "fetch-foot: $(find "$STAGE" -type f -o -type l | wc -l) files staged -> $STAGE"
