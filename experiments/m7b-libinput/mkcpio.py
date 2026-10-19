#!/usr/bin/env python3
"""Minimal newc cpio writer (the box has no cpio). Usage: mkcpio.py <dir> > out.cpio"""
import os, sys, stat
root = sys.argv[1]; out = sys.stdout.buffer; ino = [1]
def ent(name, st, data=b""):
    nb = name.encode() + b"\0"
    hdr = "070701" + "".join("%08x" % v for v in (ino[0], st.st_mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nb), 0))
    ino[0] += 1
    out.write(hdr.encode() + nb + b"\0" * ((4 - (110 + len(nb)) % 4) % 4) + data + b"\0" * ((4 - len(data) % 4) % 4))
for d, dirs, files in os.walk(root):
    dirs.sort(); files.sort()
    rel = os.path.relpath(d, root)
    if rel != ".": ent(rel, os.lstat(d))
    for l in [x for x in dirs if os.path.islink(os.path.join(d, x))]:
        dirs.remove(l); files.append(l)
    files.sort()
    for f in files:
        p = os.path.join(d, f); st = os.lstat(p); r = os.path.normpath(os.path.join(rel, f))
        if stat.S_ISLNK(st.st_mode): ent(r, st, os.readlink(p).encode())
        else: ent(r, st, open(p, "rb").read())
class Z: st_mode = 0
ent("TRAILER!!!", Z)
