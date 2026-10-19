#!/usr/bin/env python3
"""M9 checks (DESIGN-0001 section 0.4, "M9 acceptance", gated checks h1-h5 and x).
Usage: check.py <run dir> <refused-by-design.txt>
Run dir from run-m9.sh: serial.log, shot-foot.ppm (screendump after the exec dispatch, once
foot is mapped), shot.ppm (final), snap.bin (korusnap stream). Decisions fixed 2026-10-19
17:50 CEST before the first counted run (see DESIGN-0001):
  h1: the socket is evidenced by Hyprland's "Hypr socket started at $XDG_RUNTIME_DIR/hypr/<sig>/
      .socket.sock" plus hyprctl connecting to it (koru-os unix sockets have no fs node), and the
      monitors JSON lists the bochs connector (korukms names it Virtual-1, 1280x800).
  h2: two parts, both required: (h2a) the frozen trigger `hyprctl dispatch exec foot`
      (0.56 Lua form hl.dsp.exec_cmd('foot')) returns ok; (h2b) bounding-box variant (no L1
      reference exists): pixels of foot's default background #242424 form a box covering >= 50 %
      of the 1280x800 screendump, >= 90 % filled, against Hyprland's #111111 wallpaper.
"""
import io, json, os, re, sys, tarfile
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
def block(a, b):
    m = re.search(re.escape(a) + r"\n(.*?)\n" + re.escape(b), txt, re.S)
    return m.group(1) if m else None
def jload(s):
    s = "\n".join(l for l in (s or "").splitlines() if not re.match(r"^\[\s*\d+\.\d+\] ", l)).strip()
    try: return json.loads(s)
    except Exception: return None
sig = re.search(r"m9-init: signature (\S+)", txt)
sock = sig and re.search(r"Hypr socket started at /tmp/xdg/hypr/%s/\.socket\.sock" % re.escape(sig.group(1)), txt)
mon = jload(block("m9-init: monitors begin", "m9-init: monitors end"))
monok = isinstance(mon, list) and any(m.get("name") == "Virtual-1" and m.get("width") == 1280 and m.get("height") == 800 for m in mon)
chk("(h1) compositor running: IPC socket under $XDG_RUNTIME_DIR/hypr/ and monitors lists the bochs connector",
    sock and monok, "socket %s, monitors %s" % ("yes" if sock else "no", [m.get("name") for m in mon] if isinstance(mon, list) else "unparsed"))
ex = block("m9-init: dispatch exec begin", "m9-init: dispatch exec end") or ""
h2a = re.search(r"^ok$", ex, re.M) is not None and "rc=0" in ex
why = "; ".join(l.strip() for l in ex.splitlines() if "error" in l or "CLONE_VM" in l or l.startswith("rc="))
win = None
try:
    from PIL import Image
    im = Image.open(os.path.join(run, "shot-foot.ppm")).convert("RGB"); W, H = im.size
    px = im.load(); xs, ys, n = [], [], 0
    for y in range(0, H, 2):
        for x in range(0, W, 2):
            if px[x, y] == (0x24, 0x24, 0x24): xs.append(x); ys.append(y); n += 1
    if n:
        bw, bh = max(xs) - min(xs) + 2, max(ys) - min(ys) + 2
        cover, fill = bw * bh / (W * H), n * 4 / (bw * bh)
        win = (cover >= 0.5 and fill >= 0.9, "box %dx%d at %d,%d cover %.2f fill %.2f" % (bw, bh, min(xs), min(ys), cover, fill))
    else: win = (False, "no #242424 pixels")
except Exception as e: win = (False, "screendump: %s" % e)
chk("(h2a) frozen trigger hyprctl dispatch exec foot returns ok", h2a, why or "no dispatch block")
chk("(h2b) screendump shows the foot window (bounding box)", win[0], win[1])
data = None
try:
    t = tarfile.open(os.path.join(run, "snap.bin")); data = t.extractfile("tmp/dod3").read()
except Exception as e: data = "error %s" % e
chk("(h3) /tmp/dod3 recovered by the host from korusnap == b'DOD3\\n'", data == b"DOD3\n", repr(data))
cl = jload(block("m9-init: clients begin", "m9-init: clients end"))
chk("(h4) hyprctl -j clients lists class foot", isinstance(cl, list) and any(c.get("class") == "foot" for c in cl),
    str([c.get("class") for c in cl]) if isinstance(cl, list) else "unparsed")
rows = []
for k, n, extra in re.findall(r"koru-os: (ENOSYS|STUBBED|REFUSED) (\S+)([^\n]*)", txt):
    if k == "ENOSYS": rows.append(n)
    elif k == "STUBBED": rows.append("STUBBED " + n.rstrip("()"))
    else: rows.append("REFUSED " + n.replace("linux.ioctl.", "") + re.sub(r" \((evdev|kms|pty|unix)\)", "", extra).rstrip())
names = sorted(set(rows)); bad = [n for n in names if n not in rbd]
chk("(h5) refusal log classified", not bad, "%d rows, %d names%s" % (len(rows), len(names), "; unclassified " + str(bad) if bad else ""))
chk("(x) no Unikraft Crash", "Unikraft Crash" not in txt and "CRASH" not in txt)
chk("(x) disk policy: root mounted read-only, snapshot written", "mounted blkdev 0 read-only" in txt
    and "m9-init: snapshot written" in txt and re.search(r"korusnap: \d+ bytes persisted to blkdev 1", txt) is not None)
print("\n".join(res)); print("CHECKS " + ("PASS" if ok else "FAIL"))
sys.exit(0 if ok else 1)
