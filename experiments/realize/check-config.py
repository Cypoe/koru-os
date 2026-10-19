#!/usr/bin/env python3
"""R2/R3 (ACCEPTANCE.md): the derived kconfig lines hold in the resolved Unikraft config,
and when realize chose the no-scheduler row, no scheduler code is in the image.
Usage: check-config.py <tests dir with realize.txt, .config.koru_qemu-x86_64, .unikraft/build/*.dbg>"""
import os, re, subprocess, sys
d = sys.argv[1]
rt = open(os.path.join(d, "realize.txt")).read()
cfg = {}
for line in open(os.path.join(d, ".config.koru_qemu-x86_64")):
    m = re.match(r"^(CONFIG_\w+)=(.*)$", line.strip())
    if m: cfg[m.group(1)] = m.group(2).strip('"')
    m = re.match(r"^# (CONFIG_\w+) is not set$", line.strip())
    if m: cfg[m.group(1)] = "n"
derived = []
for line in rt.splitlines():
    m = re.match(r"^row: .*kconfig=(\S+)", line)
    if m and m.group(1) != "none": derived += m.group(1).split(",")
    m = re.match(r"^resource: stack -> (CONFIG_STACK_SIZE_PAGE_ORDER=\d+)", line)
    if m: derived.append(m.group(1))
ok = bool(derived)
for kv in derived:
    k, v = kv.split("=", 1); got = cfg.get(k, "n")
    good = got == v; ok &= good
    print(f"R2 {'ok  ' if good else 'FAIL'} {k}: derived {v}, resolved {got}")
nosched = "row: no-scheduler" in rt
syms = subprocess.run(["nm", os.path.join(d, ".unikraft/build/koru_qemu-x86_64.dbg")], capture_output=True, text=True, check=True).stdout.split("\n")
sched = [s for s in syms if re.search(r" (uk_sched_\w+|\w*schedcoop\w*|uk_thread_\w+)$", s)]
if nosched:
    good = not sched; ok &= good
    print(f"R3 {'ok  ' if good else 'FAIL'} no-scheduler row: {len(sched)} scheduler symbols in the image" + "".join(f"\n  {s}" for s in sched[:8]))
else:
    print(f"R3 n/a  scheduler row chosen; {len(sched)} scheduler symbols present")
print("R2/R3 PASS" if ok else "R2/R3 FAIL"); sys.exit(0 if ok else 1)
