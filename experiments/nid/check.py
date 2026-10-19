#!/usr/bin/env python3
"""NID binding layer checks N1-N10 (ACCEPTANCE.md), frozen before the counted runs.
Usage: check.py <rundir> <compile-gates.txt>  -> one line per check, then NID PASS/FAIL.
N1 recomputes every NID and interface id independently (it does not trust the image)."""
import base64, hashlib, re, sys
run, gates = sys.argv[1:3]
S = open(run + "/serial.log").read()
L = S.splitlines()
res = {}

def h64(domain, s, bits=64):
    v = int.from_bytes(hashlib.sha256((domain + s).encode()).digest()[:8], "big")
    if bits < 64: v = (v >> (64 - bits)) << (64 - bits)
    return base64.urlsafe_b64encode(v.to_bytes(8, "big")).rstrip(b"=").decode()
nid = lambda f, bits=64: h64("koruos.nid.v1|", f, bits)
iid = lambda i: h64("koruos.iid.v1|", i)
def idx(pat, start=0):
    for i in range(start, len(L)):
        if re.search(pat, L[i]): return i
    return -1

# N1: every printed nid/iid matches. Rows of the 4-bit table (foreign c/t/...) use 4 bits.
bad, n = [], 0
for l in L:
    for f, v in re.findall(r"foreign=(\S+) nid=(\S+)", l) + re.findall(r"table1: (\S+) nid=(\S+)", l):
        n += 1
        if v != nid(f, 4 if f.startswith("c/t/") else 64): bad.append(l)
    m = re.search(r"interface=(\S+) iid=(\S+)", l)
    if m:
        n += 1
        if m.group(2) != iid(m.group(1)): bad.append(l)
res["N1 NID and interface ids recomputed"] = (n >= 20 and not bad, f"{n} ids checked, {len(bad)} mismatches" + (f": {bad[0]}" if bad else ""))

# N2: two foreign names, one canonical interface, one export
b1 = idx(r"^bound: foreign=c/libc/1/fputs .*interface=koruos.console.write@1 .*export=console_com1_v1:write gen=1")
b2 = idx(r"^bound: foreign=linux/x86_64/1/write .*interface=koruos.console.write@1 .*export=console_com1_v1:write gen=1")
ok = b1 >= 0 and b2 > b1 and L[b1 + 1] == "out: hello via c/libc/1/fputs" and L[b1 + 2] == "call: n=24" \
    and L[b2 + 1] == "out: hello via linux/x86_64/1/write" and L[b2 + 2] == "call: n=30" \
    and nid("c/libc/1/fputs") != nid("linux/x86_64/1/write")
res["N2 foreign -> canonical -> export, two names one interface"] = (ok, f"bound lines {b1},{b2}")

# N3: unbound NIDs refused loudly by the layer, nothing runs
u1 = idx(r"^refused: foreign=c/libc/1/puts nid=\S+ arm=unikraft/qemu-x86_64 phase=link missing=correspondence row offered=\[none\]$")
u2 = idx(r"^refused: foreign=c/libc/2/fputs nid=\S+ arm=unikraft/qemu-x86_64 phase=link missing=correspondence row offered=\[c/libc/1/fputs\]$")
nb = idx(r"^bound: foreign=c/libc/1/clock_gettime")
quiet = u1 >= 0 and u2 > u1 and nb > u2 and not any(l.startswith("out") for l in L[u1:nb])
res["N3 unbound NID: loud refusal, no call"] = (quiet, f"refusals at {u1},{u2}; no out line before {nb}")

# N4: create on a bound foreign name is refused; no table opens
o1 = idx(r"^open1: refused reason=create would overwrite a bound foreign name \(use evolve\)$")
res["N4 no silent overwrite"] = (o1 >= 0 and not any(l.startswith("table: open") for l in L[:o1]), f"line {o1}")

# N5: admission against the realization's exports
o2 = idx(r"^open2: refused reason=provider export realizes another interface other=koruos.console.write@1$")
o3 = idx(r"^open3: refused reason=provider export not in this realization other=console_virtio_v1:write$")
o4 = idx(r"^open4: refused reason=evolve without a parent row$")
res["N5 admission: descriptor mismatch, unlinked export, orphan evolve"] = (min(o2, o3, o4) >= 0, f"lines {o2},{o3},{o4}")

# N6: the 4-bit table refuses a real collision
m = re.search(r"^open5: refused reason=nid collision at=create (\S+) .* other=(\S+)$", S, re.M)
ok = bool(m) and m.group(1) != m.group(2) and nid(m.group(1), 4) == nid(m.group(2), 4)
res["N6 NID collision refused (4-bit table)"] = (ok, m.group(0) if m else "no open5 line")

# N7: retarget keeps NIDs, bumps the generation; a stale binding is refused, not redirected
r0 = idx(r"^retarget: refused reason=provider export realizes another interface$")
r1 = idx(r"^retarget: interface=koruos.console.write@1 -> export=console_tag_v1:write rows=2 gen=2 \(NIDs unchanged\)$")
st = idx(r"^stale: held=1 now=2$")
rb = idx(r"^bound: foreign=c/libc/1/fputs nid=(\S+) .*export=console_tag_v1:write gen=2")
ok = r0 >= 0 and r1 > r0 and st > r1 and rb > st and not any("old binding after retarget" in l for l in L) \
    and L[rb + 1] == "out[tag]: re-resolved after retarget" and f"nid={nid('c/libc/1/fputs')}" in L[rb]
res["N7 retarget: same NID, new provider, stale refused"] = (ok, f"lines {r0},{r1},{st},{rb}")

# N8: evolve occludes, the old row stays
ev = idx(r"^row 1: evolve foreign=c/libc/1/fputs .*interface=koruos.console.write@2 .*export=console_com1_v2:write \(occludes a parent row\)$")
eb = idx(r"^bound: foreign=c/libc/1/fputs .*-> row 1 -> interface=koruos.console.write@2", max(ev, 0))
oc = idx(r"^table1: c/libc/1/fputs nid=\S+ -> koruos.console.write@1 -> console_com1_v1:write OCCLUDED by row 1$", max(ev, 0))
ok = ev >= 0 and eb > ev and L[eb + 1] == "out2: hello via the evolved row" and oc > eb
res["N8 evolve, don't mutate"] = (ok, f"lines {ev},{eb},{oc}")

# N9: hygiene
closes = [l for l in L if l.startswith("close:")]
ok = closes == ["close: outstanding=0"] * 2 and "nid: done" in L and not any("FAIL" in l or "CRIT" in l for l in L)
res["N9 both tables closed clean, done, no FAIL/crash"] = (ok, f"closes={closes}")

# N10: compile gates
g = open(gates).read()
res["N10 compile gates"] = ("NID-compile PASS" in g, g.strip().splitlines()[-1] if g.strip() else "empty")

allok = True
for k, (ok, why) in res.items():
    allok &= bool(ok); print(f"{'ok  ' if ok else 'FAIL'} {k}: {why}")
print("NID PASS" if allok else "NID FAIL"); sys.exit(0 if allok else 1)
