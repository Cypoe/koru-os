#!/usr/bin/env python3
"""Re-cut plex-os boot.anim ([FRAME_n]/fps: format, 240x24) into the format the plex-libs
anim.rs decoder parses (# CYBERBOOT ANIM / # FPS: / # FRAME n), 80 columns x 24 rows.
Column window: the leftmost 80 columns, i.e. what plex-os cyberboot.rs paints on its
80-column VGA screen when a frame is wider than 80 (left_pad 0, cells beyond COLS dropped).
Usage: recut.py <boot.anim> <out.anim> <frames.json>"""
import json, sys
src, dst, fj = sys.argv[1:4]
fps, frames, cur = 12, [], None
for line in open(src, encoding="utf-8").read().split("\n"):
    t = line.strip()
    if cur is None and t.startswith("fps:"):
        fps = int(t[4:].strip())
    elif t.startswith("[FRAME_"):
        cur = []; frames.append(cur)
    elif cur is not None:
        cur.append(line)
cut = []
for f in frames:
    while f and f[-1].strip() == "" and len(f) > 24: f.pop()
    rows = [l[:80].rstrip() for l in f[:24]]
    rows += [""] * (24 - len(rows))
    cut.append(rows)
with open(dst, "w", encoding="utf-8") as o:
    o.write("# CYBERBOOT ANIM 80x24 STAND-IN (re-cut of plex-os assets/boot.anim)\n# FPS: %d\n" % fps)
    for i, rows in enumerate(cut, 1):
        o.write("# FRAME %d\n" % i)
        # anim.rs treats lines starting with '#' as comments; none of the art does (checked below)
        for r in rows:
            assert not r.startswith("#"), (i, r)
            o.write((r if r else " ") + "\n")
json.dump({"fps": fps, "frames": cut}, open(fj, "w"))
print("recut: %d frames, fps %d, %d distinct bodies" % (len(cut), fps, len(set("\n".join(r) for r in cut))))
