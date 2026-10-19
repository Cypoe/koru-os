#!/usr/bin/env python3
"""M4 checks (DESIGN-0001 §0.2 "M4 acceptance for the stand-in"). Usage: check.py <serial.raw> <frames.json> <refused-by-design.txt>"""
import json, re, sys
raw = open(sys.argv[1], "rb").read()
frames = json.load(open(sys.argv[2]))["frames"]
rbd = {}
for l in open(sys.argv[3]):
    if l.strip() and not l.startswith("#"):
        k, _, why = l.rstrip("\n").partition("\t"); rbd[k] = why
txt = raw.decode("utf-8", errors="replace")
res, ok = [], True
def chk(name, cond, detail=""):
    global ok
    res.append(("PASS" if cond else "FAIL") + " " + name + (": " + detail if detail else ""))
    ok = ok and bool(cond)
m = re.search(r"Detected TTY size: (\d+)x(\d+) \(([^)]*)\)", txt)
chk("(a) Detected TTY size: 80x24", m and m.group(1) == "80" and m.group(2) == "24", "source: " + (m.group(3) if m else "none"))
chk("STAND-IN label", "STAND-IN ascii-animator (plex-libs anim.rs player; not boot-animator, Q18)" in txt)
# (b)
trailers = list(re.finditer(r"STAND-IN frame (\d+)/(\d+)\r*\n", txt))
good, seq_ok, first_bad, prev_end = 0, True, None, 0
for j, t in enumerate(trailers):
    idx = int(t.group(1))
    seg = txt[prev_end:t.start()]; prev_end = t.end()
    h = seg.rfind("\x1b[H")
    body = seg[h + 3:] if h >= 0 else seg
    lines = body.replace("\x1b[K", "").replace("\r", "").split("\n")
    if lines and lines[-1] == "": lines.pop()
    exp = frames[(idx - 1) % len(frames)]
    same = [l.rstrip() for l in lines] == [l.rstrip() for l in exp]
    if idx != (j % len(frames)) + 1: seq_ok = False  # trailers wrap to 1 when the asset loops
    if same and seq_ok and first_bad is None: good += 1
    elif first_bad is None: first_bad = "trailer #%d says frame %d, body %s" % (j + 1, idx, "matches" if same else "DIFFERS (%d lines)" % len(lines))
chk("(b) >= 24 consecutive asset-identical frames from frame 1 (asset order, wrapping)", good >= 24 and first_bad is None,
    "%d trailers, %d verified in order%s" % (len(trailers), good, "; first problem: " + first_bad if first_bad else ""))
# (c)
last = trailers[-1].end() if trailers else 0
c1 = re.search(r"\x1b\[2J\x1b\[1;1HSTAND-IN ascii-animator: SIGUSR1 after (\d+) frames in ([0-9.]+) s, exit 0", txt[last:])
chk("(c) ESC[2J ESC[1;1H then SIGUSR1/exit 0 line", c1, ("%s frames, %s s" % c1.groups()) if c1 else "")
chk("(c) t-cyb-init reports exit status 0", "t-cyb-init: ascii-animator exit status 0" in txt)
chk("(c) unikernel reports init exited with status 0", "koru-os: init exited with status 0" in txt)
# (d)
enosys = re.findall(r"koru-os: ENOSYS (\S+)( \(nr \d+\)| \(stub\))", txt)
stubbed = re.findall(r"koru-os: STUBBED (\S+)\(\)", txt)
names = sorted(set([n for n, _ in enosys] + ["STUBBED " + n for n in stubbed]))
bad = [n for n in names if n not in rbd]
chk("(d) refusal log empty or refused-by-design only", not bad,
    "%d ENOSYS rows, %d STUBBED rows, names %s%s" % (len(enosys), len(stubbed), names or "[]", "; unclassified " + str(bad) if bad else ""))
chk("(x) no Unikraft Crash", "Unikraft Crash" not in txt and "CRASH" not in txt)
print("\n".join(res)); print("CHECKS " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
