# kmain.py — the klanker-child probe: an unmodified project-owned
# klanker + its agents-* suite imports and answers under the CPython
# child. Every KL line is evidence; a refusal names the gap.
import os, sys, socket, subprocess

PYBIN = "/usr/bin/python3"  # sys.executable is empty here — no /proc/self/exe

print("KL hello", sys.version.split()[0])
print("KL pid", os.getpid())

# the package itself, unmodified off site-packages
try:
    names = os.listdir("/usr/lib/python3.12")
    print("KL diag", os.path.isdir("/usr/lib/python3.12/klanker"),
          len(names), "klanker" in names,
          os.path.exists("/usr/lib/python3.12/klanker/__init__.py"))
    print("KL path", sys.path)
    import klanker
    print("KL import", klanker.__version__)
except Exception as e:
    print("KL import refused", type(e).__name__, e)

# scripted prompt 1: `klanker sense` — the host-capability probe run
# through a REAL subprocess (fork+execve+waitpid+pipes).
try:
    r = subprocess.run(
        [PYBIN, "-m", "klanker", "sense", "--json"],
        capture_output=True, text=True, timeout=120)
    ok = r.returncode == 0 and '"python_version"' in r.stdout
    print("KL sense", ok, "rc", r.returncode)
    if not ok:
        print("KL sense err", (r.stderr or r.stdout)[-400:].replace("\n", " | "))
except Exception as e:
    print("KL sense refused", type(e).__name__, e)

# scripted prompt 2: `klanker prompt` — the adaptive system prompt,
# deterministic, no LLM. THE "answers a prompt" acceptance line.
try:
    r = subprocess.run(
        [PYBIN, "-m", "klanker", "prompt"],
        capture_output=True, text=True, timeout=120)
    ok = r.returncode == 0 and "You are Klanker" in r.stdout
    print("KL prompt", ok, "rc", r.returncode)
    if not ok:
        print("KL prompt err", (r.stderr or r.stdout)[-400:].replace("\n", " | "))
except Exception as e:
    print("KL prompt refused", type(e).__name__, e)

# bot-to-bot: two children share one unix socket through the RAM-minted
# /run/bot.sock node — parent binds+listens, the fork'd child connects.
try:
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind("/run/bot.sock")
    srv.listen(1)
    pid = os.fork()
    if pid == 0:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.connect("/run/bot.sock")
        c.sendall(b"bot-ping")
        c.close()
        os._exit(0)
    conn, _ = srv.accept()
    got = conn.recv(16)
    conn.close()
    srv.close()
    _, st = os.waitpid(pid, 0)
    print("KL botsock", got.decode(), "status", os.WEXITSTATUS(st))
except Exception as e:
    print("KL botsock refused", type(e).__name__, e)

# threading — klanker/routine.py uses it; the refusal IS the measurement
try:
    import threading
    box = {}
    t = threading.Thread(target=lambda: box.__setitem__("x", 41))
    t.start(); t.join()
    print("KL thread", box.get("x", "missing"))
except Exception as e:
    print("KL thread refused", type(e).__name__, e)

# a real turn — install_overlay writes a RAM-backed home; measured wall
# is now klanker's own provider config: "LLM_BASE_URL required (or
# provider manifest url)". The budget is generous: generate_overlays
# execs python -m <module> --help-json per installed agent module — real
# interpreter startups under emulation.
# ground truth for the kernel's E2BIG: report the env block python would marshal.
_envsz = sum(len(k) + len(v) + 2 for k, v in os.environ.items())
_envbig = max(os.environ.items(), key=lambda kv: len(kv[1]), default=("-", "-"))
print("KL envsz", _envsz, "envn", len(os.environ), "biggest", _envbig[0], len(_envbig[1]))
try:
    r = subprocess.run(
        [PYBIN, "-m", "klanker", "chat", "ping"],
        capture_output=True, text=True, timeout=150)
    print("KL chat rc", r.returncode)
    if r.returncode != 0:
        print("KL chat err", (r.stderr or r.stdout)[-400:].replace("\n", " | "))
except Exception as e:
    print("KL chat refused", type(e).__name__, e)

print("KL COMPLETE")
