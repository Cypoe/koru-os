#!/usr/bin/env python3
"""Spawn skeleton checks S1-S11 (ACCEPTANCE.md), frozen before the counted runs.
Usage: check.py <rundir> <compile-gates.txt> -> one line per check, then SPAWN PASS/FAIL."""
import re, sys
run, gates = sys.argv[1:3]
L = open(run + "/serial.log").read().splitlines()
S = "\n".join(L)
res = {}
def has(p): return any(re.search(p, l) for l in L)
def lines(p): return [l for l in L if re.search(p, l)]

# S1 empty by default: child E (first census child) sees nothing; every use refused at the seam
e = re.search(r"^spawn: reserve child=(\d+)\.1 image=census .* bag=0 \(empty by default\)", S, re.M)
E = e.group(1) if e else "?"
ok = bool(e) and has(rf"^census: child={E}\.1 bag=0$") and not has(rf"^census: child={E}\.1 sees ") \
    and has(rf"^refused: child={E}\.1 use=fd/1 verb=write phase=run \(not in bag\)$") \
    and has(rf"^refused: child={E}\.1 use=env/TERM verb=read phase=run \(not in bag\)$") \
    and has(rf"^census: child={E}\.1 wrote=no TERM=\(none\) clock_ok=yes$") and not has(rf"^child={E}\.1 fd/1:") \
    and has(rf"^manifest: child={E}\.1 .* bag=0 ambient=memory<=4096,clock,exit,yield$") and has(r"^E: status=0$")
res["S1 empty-by-default rights (only the ambient set)"] = (ok, f"child {E}")

# S2 explicit grants: the child sees exactly its manifest; granted verbs work, others refused
g = [m.group(1) for m in re.finditer(r"^spawn: reserve child=(\d+)\.1 image=census", S, re.M)]
G = g[1] if len(g) > 1 else "?"
man = [(m.group(1), m.group(2)) for m in re.finditer(rf"^manifest: child={G}\.1 grant as=(\S+) from=\S+ verbs=(\S+) across_exec=\d+ epoch=\d+ granted_by=1 why=explicit$", S, re.M)]
seen = [(m.group(1), m.group(2)) for m in re.finditer(rf"^census: child={G}\.1 sees (\S+) verbs=(\S+)$", S, re.M)]
ok = man == [("fd/1", "write"), ("env/TERM", "read")] and seen == man \
    and has(rf"^child={G}\.1 fd/1: hello from a spawned child$") \
    and has(rf"^census: child={G}\.1 wrote=yes TERM=xterm-256color clock_ok=yes$") \
    and has(rf"^refused: child={G}\.1 use=fd/1 verb=read granted=write phase=run \(verb not in bag\)$") and has(r"^G: status=2$")
res["S2 manifest = bag = what the child sees; seam enforces verbs"] = (ok, f"child {G} manifest={man} seen={seen}")

# S3 over-grant and unheld handles refused at grant; bag limit
ok = has(rf"^refused: grant child={G}\.1 handle=console verbs=write\+admin as=fd/2 reason=over-grant: verbs exceed the parent's \(amplification\) phase=grant$") \
    and has(rf"^refused: grant child={G}\.1 handle=net.raw verbs=connect as=sock/0 reason=parent does not hold this handle phase=grant$") \
    and has(rf"^refused: grant child={G}\.1 handle=console verbs=write as=fd/2 reason=bag full \(max_bag\) phase=grant$") \
    and not has(rf"^spawn: grant child={G}\.1 as=(fd/2|sock/0)")
res["S3 over-grant / unheld handle / max_bag refused"] = (ok, "")

# S4 address-space copy refused loudly, on every route
ok = has(r"^refused: fork by holder=1 reason=address-space copy is not grantable \(F2\) phase=run arm=unikraft/qemu-x86_64") \
    and has(r"^refused: reserve image=@caller holder=1 reason=no second context: continuing at the caller's instruction pointer is not grantable \(F2\) phase=reserve$") \
    and has(rf"^refused: grant child={G}\.1 handle=address-space verbs=copy as=as reason=address-space copy is not grantable \(F2\) phase=grant$") \
    and not has(r"^spawn: grant .* from=address-space")
res["S4 address-space copy refused (fork, @caller, grant)"] = (ok, "")

# S5 seal checks imports against bag + ambient
gy = re.search(r"^spawn: reserve child=(\d+)\.1 image=greedy", S, re.M)
GY = gy.group(1) if gy else "?"
ok = bool(gy) and has(rf"^refused: seal child={GY}\.1 image=greedy missing=store/ring phase=seal") and not has(rf"^manifest: child={GY}\.1") \
    and has(rf"^spawn: abandon \(no evidence it ran\) child={GY}\.1")
res["S5 seal refuses uncovered imports"] = (ok, f"child {GY}")

# S6 spawn authority: image set and child limit
ok = has(r"^refused: reserve image=evil holder=1 reason=image not in the spawn authority \(F9\) phase=reserve$") \
    and has(r"^refused: reserve image=census holder=1 reason=spawn authority has no free child slot \(max_children\) phase=reserve$")
res["S6 spawn authority (image set, max_children)"] = (ok, "")

# S7 start only on evidence
it = re.search(r"^spawn: reserve child=(\d+)\.1 image=inert", S, re.M)
IT = it.group(1) if it else "?"
ok = bool(it) and has(rf"^spawn: start child={IT}\.1 stalled \(no evidence the entry executed\)$") and not has(rf"^spawn: start child={IT}\.1 entered=yes") \
    and has(rf"^spawn: abandon \(no evidence it ran\) child={IT}\.1")
res["S7 start mints running only on evidence"] = (ok, f"child {IT}")

# S8 roster brackets every child; no zombie at the end
ok = lines(r"^roster: ") == ["roster: 0", "roster: 1", "roster: 0", "roster: 0"] and has(r"^spawn: reap child=\d+\.1 released bag=0 roster=0$") \
    and re.findall(r"roster=(\d+)$", lines(r"^spawn: (reap|abandon)")[-1]) == ["0"]
res["S8 roster n -> n+1 -> n, none left"] = (ok, f"{lines(r'^roster: ')}")

# S9 identities minted at reserve, strictly increasing, never reused (also across refusals)
ids = [int(m.group(1)) for m in re.finditer(r"^spawn: reserve child=(\d+)\.(\d+)", S, re.M)]
ok = len(ids) >= 6 and ids == sorted(ids) and len(set(ids)) == len(ids) and ids[0] == 2
res["S9 identities never reused"] = (ok, f"{ids}")

# S10 compile gates
gt = open(gates).read()
res["S10 compile gates"] = ("SPAWN-compile PASS" in gt, gt.strip().splitlines()[-1] if gt.strip() else "empty")

# S11 hygiene
ok = "spawn: done" in L and not any("FAIL" in l or "CRIT" in l for l in L)
res["S11 done, no FAIL/crash"] = (ok, "")

# S12 revoke
ok = has(r"^spawn: revoke child=\d+\.1 grant=0 as=fd/1 epoch=1 \(revoked\)$") \
    and has(r"^refused: child=\d+\.1 use=fd/1 verb=write reason=revoked epoch=1 phase=run$")
res["S12 revoke: epoch marked, write refused at seam"] = (ok, "")

# S13 nested attenuation
ok = has(r"^authority: derived holder=\d+ from child=\d+\.1 handles=1 \(nested attenuation\)$") \
    and has(r"^nested: refused reason=over-grant: verbs exceed the parent's \(amplification\)$")
res["S13 nested attenuation: over-grant refused"] = (ok, "")

allok = True
for k, (ok, why) in res.items():
    allok &= bool(ok); print(f"{'ok  ' if ok else 'FAIL'} {k}: {why}")
print("SPAWN PASS" if allok else "SPAWN FAIL"); sys.exit(0 if allok else 1)
