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

# threading — clone-threads probe: either it runs or names the gap
try:
    import threading
    box = {}
    t = threading.Thread(target=lambda: box.__setitem__("x", 41))
    t.start()
    t.join()
    print("PY thread", box.get("x", "missing"))
except Exception as e:
    print("PY thread refused", type(e).__name__, e)

# subprocess — fork+exec(+posix_spawn) through the real pipeline
try:
    import subprocess
    r = subprocess.run(["/usr/bin/python3", "-S", "-c", "print('sub-ok')"],
                       capture_output=True, text=True)
    print("PY subprocess", r.returncode, r.stdout.strip())
except Exception as e:
    print("PY subprocess refused", type(e).__name__, e)

# asyncio — selectors/epoll event loop on our channel class: call_soon
# alone never reaches epoll_wait, so the probe also sleeps (a timed
# epoll) and pushes real bytes through a loop-managed socketpair.
try:
    import asyncio, socket
    async def go():
        loop = asyncio.get_event_loop()
        f = asyncio.Future()
        loop.call_soon(f.set_result, 99)
        v = await f
        await asyncio.sleep(0.01)  # the timed epoll_wait path
        a, b = socket.socketpair()
        a.setblocking(False); b.setblocking(False)
        await loop.sock_sendall(a, b"loop-bytes")
        return v, (await loop.sock_recv(b, 10)).decode()
    print("PY asyncio", *asyncio.get_event_loop().run_until_complete(go()))
except Exception as e:
    print("PY asyncio refused", type(e).__name__, e)

print("PY COMPLETE")
