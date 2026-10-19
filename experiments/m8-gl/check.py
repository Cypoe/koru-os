#!/usr/bin/env python3
"""M8a checks (DESIGN-0001 §0.4 "M8a acceptance"). Usage: check.py <run dir> <refused-by-design.txt>"""
import os, re, sys
run, rbdf = sys.argv[1], sys.argv[2]
txt = open(os.path.join(run, "serial.log"), errors="replace").read()
txt = re.sub(r"^\[\s*[\d.]+\] ", "", txt, flags=re.M)
rbd = {}
for l in open(rbdf):
    if l.strip() and not l.startswith("#"):
        k, _, why = l.rstrip("\n").partition("\t"); rbd[k] = why
res, ok = [], True
def chk(name, cond, detail=""):
    global ok
    res.append(("PASS" if cond else "FAIL") + " " + name + (": " + detail if detail else ""))
    ok = ok and bool(cond)
H = {0: "9c784fad9c82cce9", 1: "5be5b6b059035ef9"}   # L1 twin, 2026-10-19 14:13 CEST
CLEAR = (26, 51, 76, 255)
runs = re.split(r"^gloff: client extensions:", txt, flags=re.M)[1:]
def section(i, plat):
    s = runs[i] if len(runs) > i else ""
    px = {(int(f), int(x), int(y)): tuple(int(v) for v in c.split())
          for f, x, y, c in re.findall(r"^gloff: frame (\d) px (\d+),(\d+) = ([\d ]+)$", s, re.M)}
    hs = dict((int(f), (e, h)) for f, e, h in re.findall(r"^gloff: frame (\d) glError (0x[0-9a-f]+) fnv1a64 ([0-9a-f]+)", s, re.M))
    return s, px, hs
for i, plat, tag in ((0, "platform surfaceless", "(g1) surfaceless"), (1, "platform gbm on /dev/dri/card0, backend drm", "(g3) gbm")):
    s, px, hs = section(i, plat)
    chk(tag + ": EGL 1.5 Mesa, llvmpipe LLVM 19.1.7, ES 3.2 Mesa 25.0.7, FBO complete",
        ("gloff: " + plat) in s and "gloff: EGL 1.5 vendor Mesa Project" in s
        and "gloff: GL_RENDERER llvmpipe (LLVM 19.1.7, " in s and "gloff: GL_VERSION OpenGL ES 3.2 Mesa 25.0.7" in s
        and "gloff: FBO status 0x8cd5" in s, (re.search(r"GL_RENDERER [^\n]*", s) or re.search("x^", "x") or [""])[0] if "GL_RENDERER" in s else "no renderer line")
    chk(tag + ": both frame hashes equal the L1 twin, glError 0, exit 0",
        hs.get(0) == ("0x0", H[0]) and hs.get(1) == ("0x0", H[1]) and "gloff: done, exit 0" in s, str(hs))
    if i == 0:
        r0, g0 = px.get((0, 60, 40), (0,) * 4), px.get((0, 200, 40), (0,) * 4)
        r1 = px.get((1, 200, 40), (0,) * 4)
        chk("(g2) independent pixels: clear corners, red/green corners of frame 0, rotation in frame 1",
            all(px.get((f, x, y)) == CLEAR for f in (0, 1) for x, y in ((0, 0), (255, 255)))
            and r0[0] > 150 and r0[1] < 80 and r0[2] < 80 and g0[1] > 150 and g0[0] < 80 and g0[2] < 80
            and px.get((1, 60, 40)) == CLEAR and r1[0] > 150 and r1[1] < 80 and H[0] != H[1],
            "f0 60,40 %s 200,40 %s; f1 60,40 %s 200,40 %s" % (r0, g0, px.get((1, 60, 40)), r1))
chk("(g5) both gloff runs exit 0, init exit 0",
    len(re.findall(r"^m8-init: gloff exit status 0$", txt, re.M)) == 2 and "koru-os: init exited with status 0" in txt)
rows = []
for k, n, extra in re.findall(r"koru-os: (ENOSYS|STUBBED|REFUSED) (\S+)([^\n]*)", txt):
    if k == "ENOSYS": rows.append(n)
    elif k == "STUBBED": rows.append("STUBBED " + n.rstrip("()"))
    else: rows.append("REFUSED " + n.replace("linux.ioctl.", "") + extra.replace(" (kms)", "").rstrip())
names = sorted(set(rows)); bad = [n for n in names if n not in rbd]
chk("(g4) refusal log classified", not bad, "%d rows, names %s%s" % (len(rows), names, "; unclassified " + str(bad) if bad else ""))
msgs = sorted(set(re.findall(r"^(MESA[^\n]*|kmsro[^\n]*|libEGL[^\n]*|EGL[^\n]*)$", txt, re.M)))
allowed = {"MESA-LOADER: failed to retrieve device information", "kmsro: driver missing"}
chk("(g4) Mesa messages only the classified ones (B15 sysfs; kmsro as on L1)", set(msgs) <= allowed, str(msgs))
chk("(x) no Unikraft Crash", "Unikraft Crash" not in txt and "CRASH" not in txt)
print("\n".join(res)); print("CHECKS " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
