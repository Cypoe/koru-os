#!/usr/bin/env python3
"""M8b checks (DESIGN-0001 §0.4 "M8b acceptance"). Usage: check-m8b.py <run dir> <refused-by-design.txt>"""
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
ren = re.findall(r"^Rendered (\d+) frames in ([\d.]+) sec \(([\d.]+) fps\)", txt, re.M)
chk("(c1) kmscube: EGL 1.5 Mesa, llvmpipe, >=3 progress lines, 149 frames, exit 0, 150 flips",
    "with EGL version 1.5" in txt and 'vendor: "Mesa Project"' in txt and 'renderer: "llvmpipe (LLVM 19.1.7, ' in txt
    and "Using modifier" in txt and len(ren) >= 3 and ren[-1][0] == "149"
    and "m8b-init: kmscube exit status 0" in txt and "card0 closed after 150 page flips" in txt,
    "%d progress lines, last %s" % (len(ren), ren[-1] if ren else None))
def rd(p):
    b = open(p, "rb").read(); parts = b.split(b"\n", 3); w, h = map(int, parts[1].split()); return w, h, parts[3]
shots = [os.path.join(run, "shot-%d.ppm" % i) for i in (1, 2)]
if all(os.path.exists(p) for p in shots):
    (w, h, a), (_, _, b) = rd(shots[0]), rd(shots[1]); n = w * h
    px = lambda d, i: d[3 * i:3 * i + 3]
    ng = [sum(1 for i in range(n) if px(d, i) != b"\x80\x80\x80") for d in (a, b)]
    bl = [sum(1 for i in range(n) if px(d, i) == b"\0\0\0") for d in (a, b)]
    df = sum(1 for i in range(n) if px(a, i) != px(b, i))
    chk("(c2) two screendumps 1 s apart: 1280x800, grey background, cube 5-50 %, not black, differ >= 1 %",
        (w, h) == (1280, 800) and px(a, 0) == px(b, 0) == b"\x80\x80\x80"
        and all(0.05 * n <= x <= 0.5 * n for x in ng) and all(x < 0.01 * n for x in bl) and df >= 0.01 * n,
        "%dx%d non-grey %s black %s differing %d" % (w, h, ng, bl, df))
else:
    chk("(c2) two screendumps", False, "missing")
rows = []
for k, n, extra in re.findall(r"koru-os: (ENOSYS|STUBBED|REFUSED) (\S+)([^\n]*)", txt):
    if k == "ENOSYS": rows.append(n)
    elif k == "STUBBED": rows.append("STUBBED " + n.rstrip("()"))
    else: rows.append("REFUSED " + n.replace("linux.ioctl.", "") + extra.replace(" (kms)", "").rstrip())
names = sorted(set(rows)); bad = [x for x in names if x not in rbd]
chk("(c3) refusal log classified", not bad, "%d rows, names %s%s" % (len(rows), names, "; unclassified " + str(bad) if bad else ""))
msgs = sorted(set(re.findall(r"^(MESA[^\n]*|kmsro[^\n]*|libEGL[^\n]*)$", txt, re.M)))
chk("(c4) Mesa messages only the classified ones", set(msgs) <= {"MESA-LOADER: failed to retrieve device information", "kmsro: driver missing"}, str(msgs))
chk("(x) no Unikraft Crash, init exit 0", "Unikraft Crash" not in txt and "CRASH" not in txt and "koru-os: init exited with status 0" in txt)
print("\n".join(res)); print("CHECKS " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
