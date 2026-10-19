#!/usr/bin/env python3
"""Measured worst-case stack demand of a Unikraft image (DESIGN-0001 §11.1, row evidence C -> V).

Usage: stack-demand.py <kernel.dbg> <derived stack bytes> [root=ukplat_entry2]

Static, from `objdump -d` of the unstripped image. Per function:
  frame = 8 (return address) + 8 * every `push` in the body + the largest `sub $imm,%rsp`
          + the largest `and $-N,%rsp` realignment (N - 8)
(every push counted, even on exclusive paths: over-approximation on purpose).
Edges: direct `call`/tail `jmp` to another function symbol.
Indirect calls (`call *`): charged the largest acyclic demand of any ADDRESS-TAKEN function
(start address referenced by a `lea`/`mov $` in code or stored as an 8-byte value in any
non-executable allocated section), the root excluded (re-entering the boot entry
would be recursion, not demand); conservative for one level of indirection; reported.
Cycles (recursion): the back edge is cut and the cycle is listed; the verdict says so.
Root: ukplat_entry2, the first function on the boot stack that plat/kvm/x86/setup.c sizes
with __STACK_SIZE (CONFIG_STACK_SIZE_PAGE_ORDER) and enters via uk_arch_x86_64_jump_to.
Exit 0 = demand fits; 3 = demand exceeds the derived stack (refusal).
"""
import re, subprocess, sys
from functools import lru_cache

dbg, derived = sys.argv[1], int(sys.argv[2]); root = sys.argv[3] if len(sys.argv) > 3 else "ukplat_entry2"
dis = subprocess.run(["objdump", "-d", "--no-show-raw-insn", dbg], capture_output=True, text=True, check=True).stdout
import struct
addr_of = {}
hdr = re.compile(r"^([0-9a-f]+) <([^>]+)>:$")
ins = re.compile(r"^\s*[0-9a-f]+:\s+(\S+)\s*(.*)$")
F = {}; cur = None
for line in dis.splitlines():
    m = hdr.match(line)
    if m: cur = m.group(2); addr_of[int(m.group(1), 16)] = cur; F[cur] = {"push": 0, "sub": 0, "and": 0, "calls": set(), "ind": 0}; continue
    m = ins.match(line)
    if not m or cur is None: continue
    op, arg = m.group(1), m.group(2); f = F[cur]
    if op.startswith("push"): f["push"] += 1
    elif op.startswith("sub") and arg.endswith(",%rsp") and arg.startswith("$"):
        f["sub"] = max(f["sub"], int(arg[1:-5], 16))
    elif op.startswith("and") and arg.endswith(",%rsp") and arg.startswith("$0xf"):
        f["and"] = max(f["and"], (1 << 64) - int(arg[1:-5], 16) - 8)
    elif op.startswith("call") or op.startswith("jmp"):
        if arg.startswith("*"):
            if op.startswith("call"): f["ind"] += 1
            continue
        t = re.search(r"<([^>+]+)(\+0x[0-9a-f]+)?>", arg)
        if t and t.group(1) != cur and (op.startswith("call") or t.group(2) is None):
            f["calls"].add(t.group(1))
taken = set()
for line in dis.splitlines():
    m = ins.match(line)
    if m and (m.group(1).startswith("lea") or m.group(1).startswith("mov")):
        t = re.search(r"<([^>+]+)>$", m.group(2))
        if t and t.group(1) in F: taken.add(t.group(1))
        for imm in re.findall(r"\$0x([0-9a-f]+)", m.group(2)):
            if int(imm, 16) in addr_of: taken.add(addr_of[int(imm, 16)])
raw = open(dbg, "rb").read()
shoff, = struct.unpack_from("<Q", raw, 0x28); shentsize, shnum = struct.unpack_from("<HH", raw, 0x3A)
for i in range(shnum):
    _, typ, flags, _, off, size = struct.unpack_from("<IIQQQQ", raw, shoff + i * shentsize)
    if typ == 8 or not (flags & 2) or (flags & 4): continue   # NOBITS, not ALLOC, or EXEC
    for o in range(off, off + size - 7, 8):
        v, = struct.unpack_from("<Q", raw, o)
        if v in addr_of: taken.add(addr_of[v])
taken0 = set(taken); taken.discard(root)   # an indirect call back into the root would be recursion through the boot entry; listed below
frame = {n: 8 + 8 * f["push"] + f["sub"] + f["and"] for n, f in F.items()}
cycles = set()

def demand(ind_cost):
    memo = {}
    def go(n, path):
        if n in memo: return memo[n]
        if n not in F: return 0
        best, via = 0, None
        for c in sorted(F[n]["calls"]):
            if c in path: cycles.add(" -> ".join(path[path.index(c):] + [c])); continue
            d = go(c, path + [c])[0]
            if d > best: best, via = d, c
        if F[n]["ind"] and ind_cost > best: best, via = ind_cost, "<indirect>"
        memo[n] = (frame[n] + best, via); return memo[n]
    sys.setrecursionlimit(100000)
    return go, memo

go0, _ = demand(0)
ind_who = max(taken, key=lambda n: go0(n, [n])[0]) if taken else None
ind = go0(ind_who, [ind_who])[0] if taken else 0
go1, memo = demand(ind)
total, _ = go1(root, [root])
chain, n = [], root
while n and n in memo:
    chain.append(f"{n}({frame[n]})"); n = memo[n][1]
    if n == "<indirect>": chain.append(f"<indirect: {ind}>"); break
reach = set(); st = [root]
while st:
    n = st.pop()
    if n in reach or n not in F: continue
    reach.add(n); st.extend(F[n]["calls"])
ind_sites = sum(F[n]["ind"] for n in reach)
direct_only = go0(root, [root])[0]
print(f"image: {dbg}")
print(f"root: {root}; functions: {len(F)}, reachable directly: {len(reach)}")
print(f"largest frames: " + ", ".join(f"{n}={frame[n]}" for n in sorted(reach, key=lambda n: -frame[n])[:6]))
print(f"demand, direct edges only: {direct_only} B")
print(f"indirect call sites reachable: {ind_sites}; each charged {ind} B (largest acyclic demand among {len(taken)} address-taken functions: {ind_who})")
print(f"demand, conservative: {total} B")
print(f"worst chain: " + " -> ".join(chain))
print(f"recursion cycles cut: {len(cycles)}" + ("".join(f"\n  cycle: {c}" for c in sorted(cycles)[:10])))
print(f"root address-taken (excluded as indirect target): {root in taken0}")
print(f"derived stack: {derived} B")
ok = total <= derived
print(f"verdict: {'FITS' if ok else 'REFUSED'} ({'conservative' if ok else 'conservative demand'} {total} B {'<=' if ok else '>'} {derived} B)"
      + (" modulo the listed recursion" if cycles else ""))
sys.exit(0 if ok else 3)
