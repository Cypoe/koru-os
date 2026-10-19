#!/usr/bin/env python3
"""Spawn-elf checks E1-E12 against a serial.log."""
import re, sys
from pathlib import Path

def main(log_path):
    log = Path(log_path).read_text(errors="replace")
    fails = []
    def need(name, cond, detail=""):
        if cond: print(f"ok   {name}: {detail}")
        else:
            print(f"FAIL {name}: {detail}")
            fails.append(name)

    def section(name):
        m = re.search(r"== " + re.escape(name) + r" ==\n(.*?)(?=\n== |\nspawn-elf: done)", log, re.S)
        return m.group(1) if m else ""

    need("E1 begin/done",
         "spawn-elf: begin" in log and "spawn-elf: done" in log)
    need("E2 fork refused",
         "spawn-compat: fork -> refused" in log or
         "address-space copy is not grantable (F2)" in log)
    need("E3 empty bag: exit status 0",
         "E: status=0" in section("E empty bag"))
    need("E4 empty bag: no child: lines",
         "child:" not in section("E empty bag"))
    need("E5 grants: child sees fd/1 and TERM",
         "child: fd 1 " in section("G grants") and
         "child: env TERM=xterm-spawn" in section("G grants"))
    need("E6 address-space grant refused",
         "address-space" in section("G grants"))
    need("E7 path /etc/passwd refused for child",
         "child: path /etc/passwd refused" in log or
         "use=path path=/etc/passwd" in log)
    need("E8 revoke: epoch marked and write refused",
         "spawn: revoke" in section("R revoke") and
         "reason=revoked" in section("R revoke"))
    need("E9 replace from parent refused",
         "replace: from parent rc=" in section("X replace") and
         "rc=-" in section("X replace"))
    need("E10 detach",
         "spawn: detach" in section("D detach") and
         "supervisor=init" in section("D detach") and
         "ECHILD" in section("D detach"))
    need("E11 posix_spawn compat lines",
         "spawn-compat: posix_spawn" in log and
         "why=posix-inherit" in log)
    need("E12 vfork+execve compat + roster 0",
         "spawn-compat: vfork+execve" in log and
         re.findall(r"roster: (\d+)", log)[-1] == "0")
    need("E0 no CRIT/crash",
         "CRIT" not in log and "Page fault" not in log and
         "child: FAIL" not in log)
    need("M child CR3 activate",
         "(child CR3" in log and ("mmu gate" in log or "mmu activate" in log))
    need("M hw parent-heap fault",
         "hw_probe parent_heap rc=0" in log)
    need("M hw attenuation",
         "hw_probe RO-write rc=0" in log)
    need("M ELF run on child CR3 exits 0",
         "M: ELF status=0" in section("M mmu"))
    # Gap 2: direct map / physmap aliases
    need("G2 directmap slot stripped from child PT",
         "mmu: directmap strip slot=511" in log)
    cen = re.findall(r"census phase=(\w+) .*?parent_heap_frame_aliases_undeclared=(\d+)", log)
    need("G2 census: no undeclared parent-heap frame in any child PT",
         len(cen) >= 3 and all(n == "0" for _, n in cen) and
         {"derive", "gate"} <= {p for p, _ in cen} and
         "UNDECLARED alias" not in log,
         f"{len(cen)} censuses")
    # Gap 2b: only the kernel image (+ declared grants) survives pt_clone.
    need("G2 non-image leftovers stripped",
         "mmu: strip non-image leftovers" in log)
    img_lo, img_hi = 0x100000, 0x400000
    bad = []
    for va, ln in re.findall(r"census phase=derive range va=(0x[0-9a-f]+) pa=0x[0-9a-f]+ len=(0x[0-9a-f]+)", log):
        va, ln = int(va, 16), int(ln, 16)
        in_img = img_lo <= va and va + ln <= img_hi
        heap_grant = 0x400000000 <= va < 0x500000000 and ln == 0x1000
        if not (in_img or heap_grant):
            bad.append(hex(va))
    need("G2 derive-time child PT = kernel image + grants only",
         not bad and "census phase=derive range" in log, ",".join(sorted(set(bad))))
    a = section("M mmu")
    need("G2 alias readable in parent (positive control)",
         re.search(r"A: .*rc=0 parent_readable=1 same_byte=1", a) is not None)
    need("G2 alias faults under child CR3 (hw)",
         "A: hw_probe dm_alias rc=0" in a)
    # Gap 3: real child dereference -> SIGSEGV (kill-with-reason)
    t = section("T touch")
    def st(label):
        m = re.search(r"T " + re.escape(label) + r": .* status=(-?\d+)", t)
        return int(m.group(1)) if m else None
    for lab in ("parent-heap-read", "parent-heap-write", "dm-alias-read",
                "fw-identity-read", "vga-identity-read",
                "ro-grant-write", "after-sleep-parent-heap"):
        need(f"G3 {lab} -> SIGSEGV (status 139)", st(lab) == 139, str(st(lab)))
    need("G3 ro-grant-read positive control (exit 0, value 0xa5)",
         st("ro-grant-read") == 0 and "touch read survived value=0xa5" in t)
    need("G3 only the positive control survived",
         t.count("survived") == 1)
    need("G3 after-sleep child resumed on its CR3",
         "child: slept 20000 us" in t)
    kills = re.findall(r"spawn: killed child=\S+ reason=mmu-violation sig=SIGSEGV .*class=(\S+)", t)
    need("G3 kill-with-reason lines (7) with classes",
         len(kills) == 7 and "directmap-alias" in kills and
         "parent-mapped-ungranted" in kills, str(kills))
    need("G3 signaled status seen by parent wait",
         t.count("signaled=11 (SIGSEGV)") == 7)
    need("G3 no stock SIGSEGV crash / kernel-context fault",
         "Cannot deliver SIGSEGV" not in log and
         "kernel-context fault under child CR3" not in log)

    print("SPAWN-ELF PASS" if not fails else "SPAWN-ELF FAIL")
    return 0 if not fails else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "serial.log"))
