#!/usr/bin/env python3
"""Slice A run (TCG only): boot the image, attach a status view, detach it, reattach it.

Usage: run-slice.py <kernel> <outdir>

- COM1 (stdout) -> <outdir>/serial.raw: the evidence log.
- isa-debugcon at 0x402 -> a unix socket chardev (server, no wait): the status view.
  The host view connects 1.0 s after QEMU starts, reads for 2.5 s, disconnects for
  3.5 s, reconnects and reads until QEMU closes the socket. Every received line is
  stored with its host receive time (s since QEMU start) in view-1.txt / view-2.txt.
"""
import os, socket, subprocess, sys, time

K, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
sock = os.path.join(OUT, "view.sock")
if os.path.exists(sock):
    os.unlink(sock)
cmd = ["qemu-system-x86_64", "-accel", "tcg", "-kernel", K,
       "-cpu", "qemu64,+pdpe1gb,+rdrand,+rdseed,-vmx,-svm", "-m", "32M",
       "-display", "none", "-no-reboot", "-parallel", "none", "-monitor", "none",
       "-serial", "file:" + os.path.join(OUT, "serial.raw"),
       "-chardev", "socket,id=view,path=%s,server=on,wait=off" % sock,
       "-device", "isa-debugcon,iobase=0x402,chardev=view"]
t0 = time.time()
q = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=open(os.path.join(OUT, "qemu.err"), "w"))
events = []

def ev(msg):
    events.append("%.3f %s" % (time.time() - t0, msg))

def attach(path_out, until):
    """Connect, read lines until `until` (s since start) or EOF; return lines."""
    while not os.path.exists(sock) and time.time() - t0 < 10:
        time.sleep(0.02)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock)
    ev("attach")
    s.settimeout(0.1)
    buf, lines = b"", []
    while True:
        if until is not None and time.time() - t0 >= until:
            break
        try:
            d = s.recv(4096)
        except socket.timeout:
            if q.poll() is not None and until is None:
                break
            continue
        if not d:
            break
        buf += d
        while b"\n" in buf:
            l, buf = buf.split(b"\n", 1)
            lines.append("%.3f %s" % (time.time() - t0, l.decode(errors="replace")))
    s.close()
    ev("detach")
    with open(path_out, "w") as f:
        f.write("\n".join(lines) + ("\n" if lines else ""))
    return lines

time.sleep(1.0)
attach(os.path.join(OUT, "view-1.txt"), until=3.5)
time.sleep(3.5)
attach(os.path.join(OUT, "view-2.txt"), until=None)
rc = q.wait(timeout=60)
ev("qemu exit=%d" % rc)
with open(os.path.join(OUT, "serial.raw"), "rb") as f:
    raw = f.read().decode(errors="replace")
with open(os.path.join(OUT, "serial.log"), "w") as f:
    f.write(raw.replace("\r", ""))
with open(os.path.join(OUT, "drive.txt"), "w") as f:
    f.write("\n".join(events) + "\nwall_s=%.3f accel=tcg\n" % (time.time() - t0))
print("\n".join(events))
