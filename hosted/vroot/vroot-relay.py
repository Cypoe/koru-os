#!/usr/bin/env python3
# vroot-relay: forward host WSLg unix sockets into rootfs-visible paths,
# preserving SCM_RIGHTS fd-passing (wayland passes the keymap and
# shm-pool fds as ancillary data; a byte-pump silently drops them —
# measured: wl_keyboard.keymap arrives "object expected fd"). Runs on
# the HOST — it must see both /mnt/wslg and the rootfs dir. Also feeds
# the /dev fakes: userns mknod is denied on WSL2, so random/urandom/
# zero are fifos this process keeps full.
import os, socket, select, signal, threading, array, time

R = os.environ.get("KVROOT_DIR") or os.path.expanduser("~/kvroot")
PAIRS = [
    ("/mnt/wslg/runtime-dir/wayland-0", R + "/mnt/wslg/runtime-dir/wayland-0"),
    ("/mnt/wslg/.X11-unix/X0",          R + "/tmp/.X11-unix/X0"),
    ("/mnt/wslg/runtime-dir/pulse/native", R + "/mnt/wslg/runtime-dir/pulse/native"),
]
FIFOS = {
    R + "/tmp/kvfifo-urandom": "/dev/urandom",
    R + "/tmp/kvfifo-random":  "/dev/urandom",
    R + "/tmp/kvfifo-zero":    None,
}
FDMAX = 28

def xfer(src, dst):
    try:
        msg, anc, _, _ = src.recvmsg(65536, socket.CMSG_SPACE(FDMAX * 4))
    except OSError:
        return False
    if not msg:
        return False
    fds = []
    for (lvl, typ, data) in anc:
        if lvl == socket.SOL_SOCKET and typ == socket.SCM_RIGHTS:
            fds += list(array.array("i", data))
    try:
        if fds:
            dst.sendmsg([msg], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                 array.array("i", fds))])
        else:
            dst.sendall(msg)
    except OSError:
        return False
    for fd in fds:
        os.close(fd)
    return True

def pump(a, b):
    try:
        while True:
            r, _, _ = select.select([a, b], [], [])
            for s in r:
                if not xfer(s, b if s is a else a):
                    return
    finally:
        a.close(); b.close()

def accept(ls, src):
    while True:
        c, _ = ls.accept()
        try:
            t = socket.socket(socket.AF_UNIX); t.connect(src)
        except OSError:
            c.close(); continue
        threading.Thread(target=pump, args=(c, t), daemon=True).start()

def feed(path, src):
    while True:
        try:
            w = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        except OSError:
            time.sleep(0.05); continue
        os.set_blocking(w, True)
        try:
            if src is None:
                while True: os.write(w, b"\x00" * 65536)
            else:
                with open(src, "rb", buffering=0) as r:
                    while True: os.write(w, r.read(65536))
        except OSError:
            pass
        try: os.close(w)
        except OSError: pass

socks = []
for src, dst in PAIRS:
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    try:
        os.unlink(dst)
    except FileNotFoundError:
        pass
    if not os.path.exists(src):
        print("relay: skip missing", src, flush=True); continue
    ls = socket.socket(socket.AF_UNIX)
    ls.bind(dst); ls.listen(8); socks.append((ls, src))
    print("relay:", dst, "->", src, flush=True)
for ls, src in socks:
    threading.Thread(target=accept, args=(ls, src), daemon=True).start()
for path, src in FIFOS.items():
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not os.path.exists(path):
        os.mkfifo(path, 0o666)
    threading.Thread(target=feed, args=(path, src), daemon=True).start()
signal.pause()
