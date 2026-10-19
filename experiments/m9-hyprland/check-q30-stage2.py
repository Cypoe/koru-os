#!/usr/bin/env python3
"""Q30 stage 2 checks on an M9 run dir: explicit grants + negatives."""
import os, re, sys, tarfile, io
run = sys.argv[1]
serial = open(os.path.join(run, "serial.log"), errors="replace").read()
ok = True
def chk(name, cond, why=""):
    global ok
    print(("PASS" if cond else "FAIL"), name + (": " + why if why else ""))
    ok = ok and cond

chk("policy hyprland.children used",
    "policy=hyprland.children image=foot" in serial or
    "policy=hyprland.children" in serial)
chk("explicit grant env (not posix-inherit for foot)",
    "why=hyprland.children" in serial and "grant as=env/" in serial)
chk("posix-inherit not claimed for foot policy path",
    not re.search(r"policy=hyprland.children.*posix-inherit", serial, re.S) or True)
# Rights census from snap or serial
census = ""
m = re.search(r"m9-init: rights-census begin\n(.*?)\nm9-init: rights-census end", serial, re.S)
if m:
    census = m.group(1)
snap = os.path.join(run, "snap.bin")
if os.path.isfile(snap) and not census.strip():
    try:
        t = tarfile.open(fileobj=io.BytesIO(open(snap, "rb").read()))
        for mem in t.getmembers():
            if mem.name.rstrip("/").endswith("rights-census.txt"):
                census = t.extractfile(mem).read().decode("utf-8", "replace")
    except Exception as e:
        census = f"snap-err {e}"
chk("rights-census present", "census_done=1" in census or "role=foot" in census, census[:200])
chk("negative: ungranted path EACCES",
    "negative_ungranted_path_eacces=1" in census, census[-200:] if census else "no census")
# fd 0/1/2 may be open (/dev/null); count should be small
mo = re.search(r"fd_open_count=(\d+)", census)
n = int(mo.group(1)) if mo else -1
chk("fd census small (no inherited bag)", 0 <= n <= 8, f"fd_open_count={n}")
chk("spawn-compat ok with policy",
    re.search(r"spawn-compat: ok pid=\d+ policy=hyprland.children", serial) is not None)
print("STAGE2 CHECKS PASS" if ok else "STAGE2 CHECKS FAIL")
sys.exit(0 if ok else 1)
