#!/usr/bin/env python3
"""M7b host driver (koru-os and L1 alike): waits until libinput debug-events reports the
keyboard (DEVICE_ADDED), injects keys through QMP input-send-event (PS/2), waits for the last
release, then quits QEMU (koru-os) or lets the guest finish (L1, --no-quit).
Usage: drive.py <outdir> <qemu pid> <timeout s> [--no-quit]"""
import json, os, socket, sys, time
out, qpid, tmo = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
noquit = "--no-quit" in sys.argv
SEQ = [["k"], ["o"], ["r"], ["u"], ["shift", "1"], ["ret"], ["up"], ["esc"]]
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
        time.sleep(0.1)
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
def chord(keys):
    for k in keys: key(k, True); time.sleep(0.05)
    for k in reversed(keys): key(k, False); time.sleep(0.05)
    L("sent %s" % "+".join(keys)); time.sleep(0.3)
if wait("DEVICE_ADDED"):
    time.sleep(1.0)
    for c in SEQ: chord(c)
    wait("KEY_ESC (1) released"); time.sleep(1.0)
if noquit:
    while alive() and time.time() - t0 < tmo: time.sleep(0.2)
else:
    try: cmd("quit"); L("quit sent")
    except Exception as e: L("quit failed %s" % e)
