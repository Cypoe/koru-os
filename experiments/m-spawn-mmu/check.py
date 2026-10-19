#!/usr/bin/env python3
import sys
S = open(sys.argv[1] + "/serial.log", errors="replace").read()
need = [
    "PASS gap1 fault: child cannot read parent heap",
    "PASS gap1 fault: ungranted secret",
    "PASS gap1 attenuation RO write faults",
    "PASS gap1 own ambient heap writable",
    "PASS gap2 zero-grant: parent heap fault",
    "PASS gap2 derive empty bag",
    "PASS gap3 isolation A",
    "PASS gap3 isolation B",
    "PASS gap3 stress switches",
    "M-SPAWN-MMU GAPS PASS",
]
ok = all(x in S for x in need) and "FAIL gap" not in S and "CRIT" not in S
for x in need:
    print(("ok  " if x in S else "FAIL"), x)
print("M-SPAWN-MMU GAPS PASS" if ok else "M-SPAWN-MMU GAPS FAIL")
sys.exit(0 if ok else 1)
