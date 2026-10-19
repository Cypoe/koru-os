#!/usr/bin/env python3
"""Slice A checks S9-S14 + (x), frozen before the counted runs (see ACCEPTANCE.md).
Usage: check.py <rundir> <artifacts.txt> <compile-gates.txt>   -> prints one line per check, then PASS/FAIL."""
import re, sys
run, artf, gates = sys.argv[1:4]
S = open(run + "/serial.log").read()
L = S.splitlines()
V1 = [l.split(" ", 1) for l in open(run + "/view-1.txt").read().splitlines() if l.strip()]
V2 = [l.split(" ", 1) for l in open(run + "/view-2.txt").read().splitlines() if l.strip()]
D = open(run + "/drive.txt").read()
art = {n: h for h, n in (l.split() for l in open(artf) if l.strip())}
res = {}
def idx(pat, start=0):
    for i in range(start, len(L)):
        if re.search(pat, L[i]): return i
    return -1

# S9: versioned imports declared before their binding
ok = True
for imp in ["store.bounded@1", "clock.tick@1", "view.status@1"]:
    b = idx(r"^bound: " + re.escape(imp) + " ")
    i = max([k for k in range(len(L)) if L[k].startswith("import: " + imp + " ") and k < b], default=-1) if b >= 0 else -1
    ok &= b >= 0 and i >= 0
res["S9"] = ok
# S10: the authorized, compatible, linked provider is selected; others passed over by name
s10 = (re.search(r"^bound: store\.bounded@1 -> store_mem_v1 artifact=%s " % art["store_mem_v1"][:16], S, re.M)
       and re.search(r"^passed over: store\.bounded@1 store_mem_v2\(rev 2: contract revision\) store_wide\(rev 1: entry size\)$", S, re.M)
       and re.search(r"^bound: clock\.tick@1 -> clock_uk_v1 artifact=%s " % art["clock_uk_v1"][:16], S, re.M)
       and re.search(r"^bound: view\.status@1 -> view_debugcon_v1 artifact=%s " % art["view_debugcon_v1"][:16], S, re.M))
res["S10"] = bool(s10)
# S11: three refusals, fixed shape, before any child exists
ref = [l for l in L if l.startswith("refused: interface=store.bounded@1 arm=unikraft/qemu-x86_64 phase=load missing=compatible authorized provider offered=[")]
first_reserve = idx(r"^supervisor: reserve ")
last_ref = max([k for k in range(len(L)) if L[k].startswith("refused: interface=")], default=10**9)
res["S11"] = (len(ref) == 3 and "contract revision" in ref[0] and "entry size" in ref[0]
              and "unauthorized artifact" in ref[1]
              and "artifact not in this realization" in ref[2] and "effects exceed import" in ref[2]
              and 0 <= last_ref < first_reserve and "supervisor: roster=0 after refusals" in S)
# S12: the real operation through the provider
ticks = [int(m.group(1)) for m in re.finditer(r"^task: child=2\.1 tick=(\d+) ", S, re.M)]
rel = re.findall(r"^supervisor: release child=2\.1 as=(\w+) provider=(\w+) calls=(\d+)$", S, re.M)
cost = re.search(r"^cost: store\.bounded@1 mechanism=ring\(16x64\) committed=(\d+) budget_left=(\d+)$", S, re.M)
res["S12"] = (ticks == list(range(1, 31)) and "task: readback ok entries=16 first=15 last=30" in S
              and len(rel) == 3 and all(int(c) > 0 for _, _, c in rel)
              and bool(cost) and int(cost.group(1)) + int(cost.group(2)) == 4096)
# S13: the supervisor's record and lifecycle, in order
seq = [r"^supervisor: roster=0$", r"^supervisor: reserve child=1\.1 .* roster=1$", r"^refused: child=1\.1 phase=seal missing=store",
       r"^supervisor: abandon child=1\.1 roster=0", r"^supervisor: reserve child=2\.1 image=slice-a-task artifact=%s budget=4096 roster=1$" % art["slice_task"][:16],
       r"^supervisor: grant child=2\.1 as=store ", r"^supervisor: grant child=2\.1 as=clock ", r"^supervisor: grant child=2\.1 as=view ",
       r"^supervisor: seal child=2\.1 bag=3 requires=store,clock,view", r"^supervisor: start child=2\.1 ran=yes$",
       r"^supervisor: roster=1 while running$", r"^supervisor: exited child=2\.1 status=0 ticks=30$",
       r"^supervisor: reap child=2\.1 roster=0$", r"^supervisor: roster=0 after reap; status=0 ticks=30$"]
pos, ok = 0, True
for p in seq:
    k = idx(p, pos)
    if k < 0: ok = False; break
    pos = k + 1
res["S13"] = ok and len(re.findall(r"^supervisor: start ", S, re.M)) == 1
# S14: detach and reattach the view without stopping the task
fr = lambda v: [re.match(r"view: child=(\S+) state=(\w+) tick=(\d+)/30 t_ms=\d+ store=\d+/16 evicted=\d+ held=(\d+)\.\.(\d+) last=", x) for _, x in v]
f1, f2 = fr(V1), fr(V2)
ev = dict((m.group(2), float(m.group(1))) for m in re.finditer(r"^([\d.]+) (attach|detach)$", D, re.M))
times = [(float(t), e) for t, e in re.findall(r"^([\d.]+) (attach|detach)$", D, re.M)]
gap = times[2][0] - times[1][0] if len(times) >= 3 else 0
ok = (len(f1) >= 3 and len(f2) >= 3 and all(f1) and all(f2) and gap >= 3.0
      and all(m.group(1) == "2.1" for m in f1 + f2) and all(m.group(2) == "running" for m in f1))
if ok:
    t1 = int(f1[-1].group(3)); m2 = f2[0]; t2 = int(m2.group(3))
    ok = (t2 >= t1 + 5 and int(m2.group(4)) <= t1 + 1 and int(m2.group(5)) == t2
          and f2[-1].group(2) == "exited" and f2[-1].group(3) == "30"
          and all(int(m.group(3)) >= t2 for m in f2))
res["S14"] = ok
# (x)
G = open(gates).read()
res["x"] = ("qemu exit=0" in D and "Unikraft Crash" not in S and not re.search(r"^FAIL", S, re.M)
            and "slice-a: end" in S and "SLICE-compile PASS" in G)
for k in ["S9", "S10", "S11", "S12", "S13", "S14", "x"]:
    print("%s %s" % (k, "PASS" if res[k] else "FAIL"))
print("SLICE-A " + ("PASS" if all(res.values()) else "FAIL"))
