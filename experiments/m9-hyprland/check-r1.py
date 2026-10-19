#!/usr/bin/env python3
"""R1 (foot on its own child CR3) checks: check-r1.py <rundir> <step>
Step 2: foot gets its own domain at execve (shadow mode, no CR3 activation)."""
import re, sys
run, step = sys.argv[1], int(sys.argv[2])
log = open(run + "/serial.log", errors="replace").read()
res = []
def ck(name, ok, why=""):
    res.append(ok); print(("PASS " if ok else "FAIL ") + name + ((" -- " + why) if why else ""))

created = re.findall(r"m9dom: domain dom=(\d+) created at=execve path=(\S+) policy=(\S+) thread=\S+ cr3=(0x[0-9a-f]+) mode=(\w+)", log)
ck("R1.1 exactly one domain, created at execve of /usr/bin/foot by policy hyprland.children/foot",
   len(created) == 1 and created[0][1] == "/usr/bin/foot" and created[0][2] == "hyprland.children/foot", str(created))
ck("R1.2 no refused domain", "m9dom: REFUSED" not in log)
der = re.findall(r"mmu: census phase=derive .*parent_heap_frame_aliases_undeclared=(\d+)", log)
ck("R1.3 derive census: no undeclared parent-heap alias", der != [] and all(x == "0" for x in der), str(der))
com = re.findall(r"m9dom: commit dom=1 .*census_undeclared=(-?\d+) mode=(\w+)", log)
ck("R1.4 execve commit census undeclared=0", com != [] and com[0][0] == "0", str(com))
led = re.search(r"m9dom: ledger dom=1 phase=execve vmas=(\d+) bytes=(0x[0-9a-f]+)", log)
ck("R1.5 ledger at execve owns the loaded images + stack (>=5 VMAs)", bool(led) and int(led.group(1)) >= 5, led.group(0) if led else "")
own_add = re.findall(r"m9dom: own dom=1 \+va=(0x[0-9a-f]+) len=(0x[0-9a-f]+)", log)
ck("R1.6 post-start mappings of foot attributed (>=100 owned maps)", len(own_add) >= 100, "owned maps=%d" % len(own_add))
summ = re.findall(r"m9dom: summary dom=1 .*unattributed_maps=(\d+)", log)
ck("R1.7 parent (Hyprland) mapped while the domain lived and was NOT attributed", summ != [] and int(summ[-1]) > 0, "last unattributed_maps=%s" % (summ[-1] if summ else None))
slots = [int(k) * 1024 for k in re.findall(r"memfd slot \d+: (\d+) KiB", log)]
big = [s for s in slots if s >= 1024 * 1024]
lens = {int(l, 16) for _, l in own_add}
ck("R1.8 foot's wl_shm buffers (memfd slots >=1 MiB) appear as foot-owned VMAs", big != [] and all(s in lens for s in big), "slots=%s" % [hex(s) for s in big])
if step == 2:
    ck("R2.9 shadow mode: CR3 never activated, no child faults", created != [] and created[0][4] == "shadow" and "reason=mmu-violation" not in log)
print("R1 STEP %d %s" % (step, "PASS" if all(res) else "FAIL"))
