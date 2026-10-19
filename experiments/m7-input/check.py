#!/usr/bin/env python3
"""M7a checks (DESIGN-0001 §0.4 "M7a acceptance"). Usage: check.py <run dir> <refused-by-design.txt>
Expected events are derived here from drive.py's host sequences and the set 1 table below,
independently of the guest."""
import os, re, sys
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
# qcode -> (MSC_SCAN value as Linux atkbd reports it, Linux KEY_* code)
T = {"k": (0x25, 37), "o": (0x18, 24), "r": (0x13, 19), "u": (0x16, 22), "shift": (0x2a, 42),
     "1": (0x02, 2), "ret": (0x1c, 28), "up": (0xc8, 103), "esc": (0x01, 1),
     "a": (0x1e, 30), "b": (0x30, 48)}
SEQ1 = [["k"], ["o"], ["r"], ["u"], ["shift", "1"], ["ret"], ["up"], ["esc"]]
def expect(seq):
    ev = []
    def one(k, v): sc, kc = T[k]; ev.extend([(4, 4, sc), (1, kc, v), (0, 0, 0)])
    for c in seq:
        for k in c: one(k, 1)
        for k in reversed(c): one(k, 0)
    return ev
m = re.search(r"crw\S*\s+\S+\s+\S+\s+\S+\s+13,\s+64 .* event0", txt)
chk("(i1) /dev/input/event0 is char 13,64", m, m.group(0) if m else "no ls line")
need = ["evdump: nonblock read on empty queue: -1 errno 11 (EAGAIN, ok)",
        "evdump: EVIOCGVERSION rc 0 version 0x010001", "evdump: EVIOCGID rc 0 bus 0x0011",
        "evdump: EV bits: SYN KEY MSC LED REP\n",
        "KEY_A 1 KEY_ENTER 1 KEY_UP 1 KEY_ESC 1 KEY_LEFTSHIFT 1",
        "evdump: EVIOCGREP rc 0 delay 250 period 33", "evdump: EVIOCGKEY rc >=0 keys down 0",
        "evdump: EVIOCGRAB 1: 0, again: -16, 0: 0, 0 again: -22", "evdump: READY"]
miss = [n for n in need if n not in txt]
chk("(i2) evdump identity, bits, nonblock, grab", not miss, "missing %s" % miss if miss else "")
got = [tuple(int(x) for x in g) for g in re.findall(r"^evdump: ev (\d+) (\d+) (-?\d+)$", txt, re.M)]
exp = expect(SEQ1)
first = next((i for i, (a, b) in enumerate(zip(got, exp)) if a != b), None)
chk("(i3) evdump events == derived sequence", got == exp,
    "%d events, expected %d%s" % (len(got), len(exp), "" if first is None else "; first diff at %d: %s vs %s" % (first, got[first], exp[first])))
d = re.search(r"evdump: DONE keys (\d+) syns (\d+) msc (\d+) polls (\d+) nonmonotonic (\d+) esc (\w+)", txt)
chk("(i3) evdump summary and exit 0",
    d and d.group(1, 2, 3) == ("18", "18", "18") and d.group(5) == "0" and d.group(6) == "yes"
    and "m7-init: evdump exit status 0" in txt, d.group(0) if d else "no DONE line")
ev = []
tail = txt.split("Testing ... (interrupt to exit)", 1)
if len(tail) == 2:
    for l in tail[1].splitlines():
        m1 = re.match(r"Event: time \d+\.\d+, type (\d+) \((\w+)\), code (\d+) \((\w+)\), value (\w+)", l)
        if m1: ev.append((int(m1.group(1)), int(m1.group(3)), int(m1.group(5), 16) if m1.group(1) == "4" else int(m1.group(5))))
        elif re.match(r"Event: time \d+\.\d+, -+ SYN_REPORT -+", l): ev.append((0, 0, 0))
exp2 = expect([["a"], ["b"]])
chk("(i4) unmodified evtest: version, ID, EV_KEY/KEY_ESC, a+b events in order",
    "Input driver version is 1.0.1" in txt
    and "Input device ID: bus 0x11 vendor 0x1 product 0x1 version 0xab41" in txt
    and "Event type 1 (EV_KEY)" in txt and "Event code 1 (KEY_ESC)" in txt and ev == exp2,
    "%d evtest events %s" % (len(ev), "== expected" if ev == exp2 else "!= expected %s" % exp2))
rows = []
for k, n, extra in re.findall(r"koru-os: (ENOSYS|STUBBED|REFUSED) (\S+)([^\n]*)", txt):
    if k == "ENOSYS": rows.append(n)
    elif k == "STUBBED": rows.append("STUBBED " + n.rstrip("()"))
    else: rows.append("REFUSED " + n.replace("linux.ioctl.", "") + extra.replace(" (evdev)", "").rstrip())
names = sorted(set(rows)); bad = [n for n in names if n not in rbd]
chk("(i5) refusal log classified", not bad, "%d rows, names %s%s" % (len(rows), names, "; unclassified " + str(bad) if bad else ""))
st = re.findall(r"event0 closed: (\d+) events queued, (\d+) read, (\d+) dropped; i8042 (\d+) IRQs, (\d+) ring drops", txt)
chk("(i6) no dropped events, no ring drops", st and all(s[2] == "0" and s[4] == "0" for s in st), str(st))
chk("(x) no Unikraft Crash", "Unikraft Crash" not in txt and "CRASH" not in txt)
print("\n".join(res)); print("CHECKS " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
