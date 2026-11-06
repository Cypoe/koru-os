# main.py — the CPython probe on the koru arm: every PY line is a
# syscall surface the interpreter exercised; a traceback names the
# gap that refused it. The initramfs view is read-only by design —
# the write attempt below asserts EROFS is the honest refusal.
import os, sys

print("PY hello", sys.version.split()[0])
print("PY pid", os.getpid())
print("PY argv", sys.argv[-1])

# fs read through the view (this file itself is a known object)
with open("/main.py") as f:
    print("PY read", len(f.read()), "bytes")

# write intent on the read-only initramfs view: the honest refusal is EROFS(30)
try:
    open("/pyx.txt", "w").close()
    print("PY write unexpected-success")
except OSError as e:
    print("PY write refused errno", e.errno)

# fork + waitpid — the create family
pid = os.fork()
if pid == 0:
    os.write(1, b"PY child says hi\n")
    os._exit(7)
wp, st = os.waitpid(pid, 0)
print("PY fork", wp == pid, "status", os.WEXITSTATUS(st))

# pipe — the channel class
r, w = os.pipe()
os.write(w, b"pipe-bytes")
print("PY pipe", os.read(r, 10).decode())
os.close(r)
os.close(w)

print("PY COMPLETE")
