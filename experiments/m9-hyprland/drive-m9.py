#!/usr/bin/env python3
"""M9 host driver: waits for guest markers, takes screendumps, types `echo DOD3 > /tmp/dod3`
+ Enter into the focused window through QMP input-send-event (PS/2 keyboard), then quits.
Usage: drive-m9.py <outdir> <qemu pid> <timeout s>"""
import json, os, socket, sys, time
out, qpid, tmo = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
K = {" ": ["spc"], ">": ["shift", "dot"], "/": ["slash"], "\n": ["ret"]}
TEXT = "echo DOD3 > /tmp/dod3\n"
log = open(out + "/drive.txt", "w"); t0 = time.time()
def L(m): log.write("%.2f %s\n" % (time.time() - t0, m)); log.flush()
def serial():
    try: return open(out + "/serial.raw", "rb").read().decode("utf-8", "replace")
    except FileNotFoundError: return ""
def alive():
    try: os.kill(qpid, 0); return True
    except OSError: return False
def wait(marker):
    while time.time() - t0 < tmo and alive():
        if marker in serial(): L("seen %r" % marker); return True
        time.sleep(0.2)
    L("NOT seen %r" % marker); return False
q = None
for _ in range(100):
    try: q = socket.socket(socket.AF_UNIX); q.connect(out + "/qmp.sock"); break
    except OSError: time.sleep(0.1)
f = q.makefile("rw")
def cmd(c, a=None):
    m = {"execute": c}
    if a is not None: m["arguments"] = a
    f.write(json.dumps(m) + "\n"); f.flush()
    while True:
        r = json.loads(f.readline())
        if "return" in r or "error" in r:
            if "error" in r: L("QMP error %s" % r)
            return r
json.loads(f.readline()); cmd("qmp_capabilities")
def key(k, down): cmd("input-send-event", {"events": [{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": k}}}]})
def ev(k, down): return {"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": k}}}
def chord(keys):
    # presses and releases in one QMP command: under TCG a separate release can reach the
    # client after its key-repeat delay (rehearsal 3 typed "eeeeecho")
    cmd("input-send-event", {"events": [ev(k, True) for k in keys] + [ev(k, False) for k in reversed(keys)]})
    time.sleep(0.4)
def ch2keys(c):
    if c in K: return K[c]
    if c.isupper(): return ["shift", c.lower()]
    return [c]
def shot(name): cmd("screendump", {"filename": out + "/" + name}); L("screendump " + name)
if wait("m9-init: foot mapped after"):
    time.sleep(8); shot("shot-foot.ppm")
    for c in TEXT: chord(ch2keys(c))
    L("typed %r" % TEXT)
wait("m9-init: end"); time.sleep(1); shot("shot.ppm"); time.sleep(1)
try: cmd("quit"); L("quit sent")
except Exception as e: L("quit failed %s" % e)
