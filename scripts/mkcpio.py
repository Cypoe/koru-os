#!/usr/bin/env python3
"""mkcpio.py — emit a cpio-newc ("070701") archive.

usage: mkcpio.py OUT.cpio SPEC [SPEC ...]

SPEC forms (ARCNAME is the archive path, no leading slash):
  dir/                      -> directory entry, mode 040755
  name=path[#GROUP][|PERM] -> regular file, PERM octal (e.g. |755);
                              same GROUP shares ino, nlink = group size
  name=->TARGET             -> symlink, mode 0120777, TARGET is link data

Inode assignment: grouped entries share one ino (nlink = group size);
ungrouped files get sequential inos. All uid/gid/mtime/rdev = 0.
The archive is padded to a 512-byte boundary after TRAILER!!!.
"""
import os
import sys


def pad4(n):
    return (4 - (n % 4)) % 4


def nalign_name(namelen):
    # N_ALIGN from the kernel's initramfs parser: ((len+1) & ~3) + 2 —
    # the +2 pays the 110-byte header's own 2-byte misalignment.
    return ((namelen + 1) // 4) * 4 + 2


def entry(name, mode, ino, nlink, data):
    namesize = len(name) + 1  # includes NUL
    hdr = b"070701" + b"".join(
        b"%08x" % v
        for v in (ino, mode, 0, 0, nlink, 0, len(data), 0, 0, 0, 0, namesize, 0)
    )
    assert len(hdr) == 110
    namefield = name.encode() + b"\0"
    namefield += b"\0" * (nalign_name(namesize) - namesize)
    return hdr + namefield + data + b"\0" * pad4(len(data))


def main():
    out = sys.argv[1]
    specs = sys.argv[2:]
    parsed = []  # (arcname, kind, mode, src, group)
    groups = {}
    for spec in specs:
        arc, _, src = spec.partition("=")
        if arc.endswith("/"):
            parsed.append((arc.rstrip("/"), "dir", 0o040755, None, None))
        elif src.startswith("->"):
            parsed.append((arc, "link", 0o120777, src[2:], None))
        else:
            # reg file: src = path[#GROUP][|PERM] — strip |PERM then #GROUP
            s = src
            perm = 0o644
            if "|" in s:
                s, _, pm = s.rpartition("|")
                perm = int(pm, 8)
            group = None
            if "#" in s:
                s, _, group = s.rpartition("#")
            path = s
            mode = 0o100000 | perm
            if group is not None:
                groups.setdefault(group, []).append(len(parsed))
            parsed.append((arc, "reg", mode, path, group))

    # assign inos: groups share, files sequential after
    ino_of = [0] * len(parsed)
    next_ino = 1
    group_ino = {}
    for i, (_, kind, _, _, group) in enumerate(parsed):
        if kind == "dir":
            continue
        if group is not None:
            if group not in group_ino:
                group_ino[group] = next_ino
                next_ino += 1
            ino_of[i] = group_ino[group]
        else:
            ino_of[i] = next_ino
            next_ino += 1
    for i, (_, kind, _, _, group) in enumerate(parsed):
        if kind == "dir":
            ino_of[i] = next_ino
            next_ino += 1

    nlink_of = [1] * len(parsed)
    for g, idxs in groups.items():
        for i in idxs:
            nlink_of[i] = len(idxs)
    for i, (_, kind, _, _, _) in enumerate(parsed):
        if kind == "dir":
            nlink_of[i] = 2

    blob = b""
    for i, (arc, kind, mode, src, _) in enumerate(parsed):
        if kind == "reg":
            with open(src, "rb") as f:
                data = f.read()
        elif kind == "link":
            data = src.encode()
        else:
            data = b""
        blob += entry(arc, mode, ino_of[i], nlink_of[i], data)

    blob += entry("TRAILER!!!", 0, 0, 1, b"")
    blob += b"\0" * ((512 - (len(blob) % 512)) % 512)
    with open(out, "wb") as f:
        f.write(blob)
    print(f"mkcpio: {out} entries={len(parsed)} bytes={len(blob)}")


if __name__ == "__main__":
    main()
