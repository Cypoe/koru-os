#!/usr/bin/env python3
import sys
S = open(sys.argv[1] + "/serial.log", errors="replace").read()
need = [
    "PASS step2 fault-on-violation (ungranted secret)",
    "PASS step2 attenuation (RO: write faults)",
    "PASS step2 fault after revoke",
    "PASS step3 cow write faults before break",
    "PASS step3 no ambient AS copy (other faults)",
    "PASS step3 writable after cow_break",
    "PASS step4 child AS: secret fault",
    "PASS step4 attenuation RO",
    "M-SPAWN-MMU STEPS PASS",
]
ok = all(x in S for x in need) and "FAIL step" not in S and "CRIT" not in S
for x in need:
    print(("ok  " if x in S else "FAIL"), x)
print("M-SPAWN-MMU STEPS PASS" if ok else "M-SPAWN-MMU STEPS FAIL")
sys.exit(0 if ok else 1)
