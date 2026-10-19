#!/usr/bin/env python3
"""M-SPAWN-MMU step-1 checks. Usage: check.py <rundir> -> STEP1 PASS/FAIL."""
import sys
S = open(sys.argv[1] + "/serial.log", errors="replace").read()
checks = [
    ("pt_clone", "pt_clone ok" in S),
    ("unmap drops child PTE", "child_present_after_unmap=0" in S),
    ("parent keeps PTE", "parent_present_after_child_unmap=1" in S),
    ("fault-on-violation", "PASS fault-on-violation (ungranted secret)" in S),
    ("explicit grant", "PASS explicit grant readable" in S),
    ("parent intact", "PASS parent secret intact" in S),
    ("no CRIT", "CRIT" not in S and "Page fault" not in S.replace("fault-on-violation", "")),
]
ok = True
for name, c in checks:
    print(("ok  " if c else "FAIL"), name)
    ok &= c
print("M-SPAWN-MMU STEP1 PASS" if ok and "M-SPAWN-MMU STEP1 PASS" in S else "M-SPAWN-MMU STEP1 FAIL")
sys.exit(0 if ok and "M-SPAWN-MMU STEP1 PASS" in S else 1)
