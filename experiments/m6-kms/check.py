#!/usr/bin/env python3
"""M6 checks (DESIGN-0001 §0.4 "M6 acceptance"). Usage: check.py <run dir> <refused-by-design.txt>"""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import expected
run, rbdf = sys.argv[1], sys.argv[2]
txt = open(os.path.join(run, "serial.log"), errors="replace").read()
rbd = {}
for l in open(rbdf):
    if l.strip() and not l.startswith("#"):
        k, _, why = l.rstrip("\n").partition("\t"); rbd[k] = why
res, ok = [], True
def chk(name, cond, detail=""):
    global ok
    res.append(("PASS" if cond else "FAIL") + " " + name + (": " + detail if detail else ""))
    ok = ok and bool(cond)
c = re.search(r"kmsdumb: crtc (\d+) connector (\d+) type (\d+) connection (\d+), \d+ modes:([^\n]*)", txt)
bufs = re.findall(r"kmsdumb: buffer ([AB]) handle \d+ pitch (\d+) size (\d+) fb (\d+)", txt)
chk("(k1) kmsdumb: connected Virtual connector with 1024x768, two dumb buffers, exit 0",
    c and c.group(3) == "15" and c.group(4) == "1" and " 1024x768" in c.group(5) and len(bufs) == 2
    and "kmsdumb: done, exit 0" in txt,
    ("crtc %s connector %s modes%s; buffers %s" % (c.group(1), c.group(2), c.group(5), bufs)) if c else "no connector line")
def frame(tag, kind, f):
    p = os.path.join(run, f)
    if not os.path.exists(p):
        chk(tag, False, "no screendump %s" % f); return
    W, H, bad, s = expected.compare(p, kind, 1024, 768)
    chk(tag, bad == 0, "%dx%d, %d mismatched pixels of %d%s" % (W, H, bad, W * H, (" first " + str(s)) if s else ""))
frame("(k2) PHASE A screendump == pattern A", "A", "shot-A.ppm")
frame("(k3) PHASE B screendump == pattern B", "B", "shot-B.ppm")
chk("(k4) modetest set 1024x768 on Virtual-1 crtc 32 and exited 0",
    "setting mode 1024x768-60.00Hz on connectors Virtual-1, crtc 32" in txt and "m6-init: modetest exit status 0" in txt)
frame("(k4) modetest screendump == libdrm SMPTE (XR24)", "SMPTE", "shot-SMPTE.ppm")
probe = re.search(r"kmsdumb: probe CLIENT_CAP_ATOMIC -> (-?\d+) errno (\d+)", txt)
chk("(k5) atomic probe refused loudly (EOPNOTSUPP + REFUSED row)",
    probe and probe.group(1) == "-1" and probe.group(2) == "95"
    and "REFUSED linux.ioctl.DRM_IOCTL_SET_CLIENT_CAP cap 3 (kms)" in txt,
    probe.group(0) if probe else "no probe line")
rows = []
for k, n, extra in re.findall(r"koru-os: (ENOSYS|STUBBED|REFUSED) (\S+)([^\n]*)", txt):
    if k == "ENOSYS": rows.append(n)
    elif k == "STUBBED": rows.append("STUBBED " + n.rstrip("()"))
    else:
        n = n.replace("linux.ioctl.", "")
        e = extra.replace(" (kms)", "").strip()
        rows.append("REFUSED " + n + ((" " + e) if e else ""))
names = sorted(set(rows)); bad = [n for n in names if n not in rbd]
chk("(k5) refusal log classified", not bad, "%d rows, names %s%s" % (len(rows), names, "; unclassified " + str(bad) if bad else ""))
chk("(k6) init exited with status 0", "koru-os: init exited with status 0" in txt)
chk("(x) no Unikraft Crash", "Unikraft Crash" not in txt and "CRASH" not in txt)
print("\n".join(res)); print("CHECKS " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
