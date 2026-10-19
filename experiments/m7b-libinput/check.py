#!/usr/bin/env python3
"""M7b checks (DESIGN-0001 §0.4 "M7b acceptance").
Usage: check.py <run dir> <refused-by-design.txt> [<L1 evidence dir>]
The L1 references (evidence/l1-debian: systemd-udevd + libudev, evidence/l1-zero: libudev-zero)
were recorded before the freeze; the key sequence is derived here from drive.py's host sequence."""
import os, re, sys
run, rbdf = sys.argv[1], sys.argv[2]
L1 = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "evidence")
txt = open(os.path.join(run, "serial.log"), errors="replace").read()
l1d = open(os.path.join(L1, "l1-debian", "serial.log"), errors="replace").read()
l1z = open(os.path.join(L1, "l1-zero", "serial.log"), errors="replace").read()
rbd = {}
for l in open(rbdf):
    if l.strip() and not l.startswith("#"):
        k, _, why = l.rstrip("\n").partition("\t"); rbd[k] = why
res, ok = [], True
def chk(name, cond, detail=""):
    global ok
    res.append(("PASS" if cond else "FAIL") + " " + name + (": " + detail if detail else ""))
    ok = ok and bool(cond)
def heads(t):
    """files dumped by `head` in m7b-init (koru) -> {path: content}"""
    s = t.split("==== SYSFS", 1)[-1].split("==== END sysfs", 1)[0]
    out = {}
    for m in re.finditer(r"^==> (\S+) <==\n(.*?)(?=^==> |\Z)", s, re.S | re.M):
        out[m.group(1)] = m.group(2).strip("\n")
    return out
def links(t):
    """`ls -lR /sys` (koru) or `ls -l` (L1) -> {path: target}"""
    out, cur = {}, None
    for l in re.sub(r"\x1b\[[0-9;]*m", "", t).splitlines():
        m = re.match(r"^(/sys\S*):$", l)
        if m: cur = m.group(1); continue
        m = re.match(r"^l\S+\s+\d+\s+\S+\s+\S+\s+\d+ \w+ +\d+ [\d:]+ (\S+) -> (\S+)$", l)
        if m:
            p = m.group(1)
            out[p if p.startswith("/") else (cur or "") + "/" + p] = m.group(2)
    return out
def l1_uevents(t):
    out = {}
    for d, body in re.findall(r"==== UEVENT (\S+)\n(.*?)==== END", t, re.S):
        lines = body.strip("\n").split("\n")
        out[d] = ("\n".join(x for x in lines if not x.startswith("SUBSYSTEM-LINK")),
                  next((x[15:] for x in lines if x.startswith("SUBSYSTEM-LINK")), ""))
    return out
def kv(s): return dict(l.split("=", 1) for l in s.splitlines() if "=" in l)
def bits(s):
    v = 0
    for w in s.split(): v = (v << 64) | int(w, 16)
    return v
# (b1) the kernel's sysfs view
H, LK, U = heads(txt), links(txt), l1_uevents(l1d)
I0 = "/sys/devices/platform/i8042/serio0/input/input0"; E0 = I0 + "/event0"
PCI = "/sys/devices/pci0000:00/0000:00:03.0"; C0 = PCI + "/drm/card0"
m = re.search(r"koru-os: INFO sysfs view on /sys: (\d+) entries, (\d+) errors", txt)
probs = []
if not m or m.group(2) != "0": probs.append("sysfs INFO line %s" % (m.group(0) if m else "missing"))
for d in (E0, C0):
    if H.get(d + "/uevent") != U.get(d, ("?",))[0]: probs.append("%s/uevent %r != L1 %r" % (d, H.get(d + "/uevent"), U.get(d, ("?",))[0]))
for d in (E0, I0, "/sys/devices/platform/i8042/serio0", "/sys/devices/platform/i8042", C0, PCI):
    if LK.get(d + "/subsystem") != U.get(d, ("", "?"))[1]: probs.append("%s/subsystem -> %s != L1 %s" % (d, LK.get(d + "/subsystem"), U.get(d, ("", "?"))[1]))
l1links = links(l1d)
for p in ("/sys/dev/char/13:64", "/sys/dev/char/226:0", "/sys/class/input/event0", "/sys/class/drm/card0"):
    if LK.get(p) != l1links.get(p): probs.append("%s -> %s != L1 %s" % (p, LK.get(p), l1links.get(p)))
ku, lu = kv(H.get(I0 + "/uevent", "")), kv(U.get(I0, ("",))[0])
for k in ("PRODUCT", "PHYS", "PROP", "EV", "MSC", "LED"):
    if ku.get(k) != lu.get(k): probs.append("input0 %s=%s != L1 %s" % (k, ku.get(k), lu.get(k)))
kb, lb = bits(ku.get("KEY", "")), bits(lu.get("KEY", ""))
need = [1, 2, 19, 22, 24, 28, 30, 37, 42, 48, 103]
if kb & ~lb or any(not (kb >> b) & 1 for b in need): probs.append("input0 KEY not a subset of L1's or misses %s" % need)
ma = "input:b0011v0001p0001eAB41-e0,1,4,11,14,k" + "".join("%X," % b for b in range(0x71, 0x300) if (kb >> b) & 1) + "ram4,l0,1,2,sfw"
if ku.get("MODALIAS") != ma: probs.append("input0 MODALIAS %s != derived %s" % (ku.get("MODALIAS"), ma))
chk("(b1) sysfs view: uevents, subsystem and dev/class links as L1; input0 bitmaps", not probs,
    "; ".join(probs) if probs else "%s entries; input0 KEY %d codes (L1 %d)" % (m.group(1), bin(kb).count("1"), bin(lb).count("1")))
# (b2) libudev-zero view == L1 libudev-zero twin; ID_INPUT* as udevd on L1
def probe(t): return [l for l in t.splitlines() if re.match(r"udevprobe: (/dev/(input/event0|dri/card0)|enumerate drm)", l)]
kp, lp = probe(txt), probe(l1z)
db = re.search(r"==== UDEVDB /run/udev/data/c13:64\n(.*?)==== END", l1d, re.S)
idp = ["ID_INPUT=1", "ID_INPUT_KEY=1", "ID_INPUT_KEYBOARD=1"]
dbok = db and all("E:" + p in db.group(1) for p in idp) and all("udevprobe: /dev/input/event0 prop " + p in kp for p in idp)
enin = "udevprobe: enumerate input: event0 devnode=/dev/input/event0" in txt
diff = [x for x in kp if x not in lp] + [x for x in lp if x not in kp]
chk("(b2) libudev view (udevprobe) == L1 libudev-zero twin; ID_INPUT/KEY/KEYBOARD as L1 udevd",
    kp and kp == lp and dbok and enin and "m7b-init: udevprobe exit status 0" in txt,
    "%d lines%s%s" % (len(kp), "" if kp == lp else "; differ: %s" % diff[:4], "" if dbok else "; ID_INPUT* mismatch"))
# (b3) unmodified libinput debug-events
T = {"k": "KEY_K (37)", "o": "KEY_O (24)", "r": "KEY_R (19)", "u": "KEY_U (22)", "shift": "KEY_LEFTSHIFT (42)",
     "1": "KEY_1 (2)", "ret": "KEY_ENTER (28)", "up": "KEY_UP (103)", "esc": "KEY_ESC (1)"}
SEQ = [["k"], ["o"], ["r"], ["u"], ["shift", "1"], ["ret"], ["up"], ["esc"]]
exp = []
for c in SEQ:
    exp += ["%s pressed" % T[k] for k in c] + ["%s released" % T[k] for k in reversed(c)]
def keys(t): return re.findall(r"^ event0\s+KEYBOARD_KEY\s+\+\S+\s+(\S+ \(\d+\) (?:pressed|released))$", t, re.M)
def added(t): return re.findall(r"^-event0\s+DEVICE_ADDED\s+(.*?)\s+(seat0 default group1\s+cap:k)\s*$", t, re.M)
kk, ad = keys(txt), added(txt)
chk("(b3) libinput debug-events: DEVICE_ADDED seat0/default/group1/cap:k, 18 keys == derived == L1 (both)",
    len(ad) == 1 and kk == exp and keys(l1d) == exp and keys(l1z) == exp,
    "added %s; %d key lines%s" % (ad, len(kk), "" if kk == exp else ", first diff %s" % next(((a, b) for a, b in zip(kk + [""] * 18, exp) if a != b), None)))
# (b4) refusal log
rows = []
for k, n, extra in re.findall(r"koru-os: (ENOSYS|STUBBED|REFUSED) (\S+)([^\n]*)", txt):
    if k == "ENOSYS": rows.append(n)
    elif k == "STUBBED": rows.append("STUBBED " + n.rstrip("()"))
    else: rows.append("REFUSED " + n.replace("linux.ioctl.", "") + re.sub(r" \((evdev|kms)\)", "", extra).rstrip())
names = sorted(set(rows)); bad = [n for n in names if n not in rbd]
chk("(b4) refusal log classified", not bad, "%d rows, names %s%s" % (len(rows), names, "; unclassified " + str(bad) if bad else ""))
st = re.findall(r"event0 closed: (\d+) events queued, (\d+) read, (\d+) dropped; i8042 (\d+) IRQs, (\d+) ring drops", txt)
chk("(b5) no Unikraft Crash; no dropped events where a close line exists",
    "Unikraft Crash" not in txt and "CRASH" not in txt and all(s[2] == "0" and s[4] == "0" for s in st), str(st))
print("\n".join(res)); print("CHECKS " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
