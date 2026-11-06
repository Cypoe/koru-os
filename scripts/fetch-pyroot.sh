#!/bin/bash
# fetch-pyroot.sh — assemble the CPython-on-Alpine payload for the
# py-cpython-child probe (koruos/native/tests/pyroot.cpio).
#
# Downloads the alpine v3.20 `python3` apk + its full .so dependency
# closure (musl, libpython3.12, libffi, libssl/libcrypto, sqlite, etc.),
# trims /usr/lib/python3.12 to the subset the interpreter boot + the
# probe actually need, adds /bin/pyrun (musl stub that execve()s
# python3 with the real argv) and /main.py, then emits a cpio-newc
# archive WITHOUT the "." root entry (the kernel parser refuses it:
# "./" canonizes to "/" and collides with the synthesized root).
#
# usage: fetch-pyroot.sh [OUT.cpio]   (default: tests/pyroot.cpio)
# Runs inside WSL — invoked from check-boot.sh as:
#   wsl bash <this-script-posix-path> [out-posix-path]
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/koruos/native/tests/pyroot.cpio}"
STAGE=/home/$USER/pystage-koru
mkdir -p "$STAGE/apks" "$STAGE/root"
cd "$STAGE/apks"
for f in \
  python3-3.12.13-r0.apk \
  gdbm-1.23-r1.apk \
  libbz2-1.0.8-r6.apk \
  libcrypto3-3.3.7-r0.apk \
  libexpat-2.8.1-r0.apk \
  libffi-3.4.6-r0.apk \
  libncursesw-6.4_p20240420-r2.apk \
  libpanelw-6.4_p20240420-r2.apk \
  libssl3-3.3.7-r0.apk \
  mpdecimal-4.0.0-r0.apk \
  musl-1.2.5-r4.apk \
  readline-8.2.10-r0.apk \
  sqlite-libs-3.45.3-r3.apk \
  xz-libs-5.8.3-r0.apk \
  zlib-1.3.2-r0.apk \
  libgcc-13.2.1_git20240309-r1.apk \
  libstdc++-13.2.1_git20240309-r1.apk ; do
  [ -s "$f" ] || curl -fsSL "https://dl-cdn.alpinelinux.org/alpine/v3.20/main/x86_64/$f" -o "$f"
done
echo "fetch-pyroot: apks ready"
cd "$STAGE/root"
for a in "$STAGE"/apks/*.apk; do tar xzf "$a" 2>/dev/null || true; done
find . -name '.PKGINFO' -delete
PY=usr/lib/python3.12
rm -rf "$STAGE/keep" && mkdir -p "$STAGE/keep"
for p in encodings codecs.py io.py abc.py _collections_abc.py \
         collections os.py stat.py posixpath.py genericpath.py \
         _bootlocale.py types.py warnings.py keyword.py reprlib.py \
         enum.py functools.py operator.py _weakrefset.py weakref.py \
         copyreg.py heapq.py \
         threading.py subprocess.py selectors.py \
         asyncio socket.py ssl.py contextlib.py traceback.py \
         linecache.py tokenize.py token.py textwrap.py fnmatch.py \
         locale.py concurrent re logging queue.py inspect.py \
         reprlib.py types.py signal.py string.py dataclasses.py \
         ast.py dis.py opcode.py importlib contextvars.py typing.py \
         bisect.py random.py hashlib.py copy.py tempfile.py; do
  [ -e "$PY/$p" ] && mkdir -p "$STAGE/keep/$(dirname "$p")" && cp -r "$PY/$p" "$STAGE/keep/$p"
done
# lib-dynload: only the extensions the interpreter/probe can name —
# posix_spawn, selectors, sockets, asyncio core, sqlite/ssl for the
# klanker rung. The fat (codecs_*/unicodedata/tests) stays out —
# a 26MiB cpio module crashes GRUB's module placement pre-serial.
mkdir -p "$STAGE/keep/lib-dynload"
for so in _posixsubprocess select _socket _asyncio _queue _contextvars \
          fcntl termios zlib array math _struct _sqlite3 _ssl _json \
          _datetime _bisect _heapq _random _opcode _multiprocessing \
          mmap binascii unicodedata _ast; do
  f=$(ls "$PY/lib-dynload/${so}.cpython-312"*.so 2>/dev/null | head -1)
  [ -n "$f" ] && cp "$f" "$STAGE/keep/lib-dynload/"
done
rm -rf "$PY" && mkdir -p "$PY" && cp -r "$STAGE/keep/." "$PY/" && rm -rf "$STAGE/keep"
mkdir -p bin
cp "$ROOT/koruos/native/tests/pyrun.elf" bin/pyrun
chmod 755 bin/pyrun
cp "$ROOT/koruos/native/tests/main.py" main.py
find . -mindepth 1 | LC_ALL=C sort | cpio -o -H newc > "$STAGE/pyroot.cpio"
cp "$STAGE/pyroot.cpio" "$OUT"
echo "fetch-pyroot: $OUT written ($(du -h "$OUT" | cut -f1))"
