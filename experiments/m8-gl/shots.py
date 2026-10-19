#!/usr/bin/env python3
"""M8b host side: after the marker appears on the serial log, take QMP screendumps at +T0 and
+T0+1 s (two frames 1 s apart); defaults: kmscube's first "Rendered " line, T0 1 s. Usage: shots.py <outdir> <qemu pid> <timeout s> [marker] [T0]"""
import json, os, socket, sys, time
out, qpid, tmo = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
marker = sys.argv[4] if len(sys.argv) > 4 else "Rendered "
t0s = float(sys.argv[5]) if len(sys.argv) > 5 else 1.0
log = open(out + "/shots.txt", "w"); t0 = time.time()
def L(m): log.write("%.2f %s\n" % (time.time() - t0, m)); log.flush()
def serial():
    try: return open(out + "/serial.raw", "rb").read().decode("utf-8", "replace")
    except FileNotFoundError: return ""
def alive():
    try: os.kill(qpid, 0); return True
    except OSError: return False
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
        if "return" in r or "error" in r: return r
json.loads(f.readline()); cmd("qmp_capabilities")
while time.time() - t0 < tmo and alive() and marker not in serial(): time.sleep(0.1)
if marker in serial():
    L("seen %r" % marker); time.sleep(t0s)
    for n in ("shot-1.ppm", "shot-2.ppm"):
        r = cmd("screendump", {"filename": out + "/" + n}); L("%s %s" % (n, "ok" if "return" in r else r))
        if n == "shot-1.ppm": time.sleep(1.0)
else: L("NOT seen %r" % marker)
while time.time() - t0 < tmo and alive(): time.sleep(0.2)
