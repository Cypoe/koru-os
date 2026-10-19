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

    print("SPAWN-ELF PASS" if not fails else "SPAWN-ELF FAIL")
    return 0 if not fails else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "serial.log"))
