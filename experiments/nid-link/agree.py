#!/usr/bin/env python3
"""L1 (ACCEPTANCE.md): the build-time link phase (realize.txt `predict:` lines) agrees with
what the image did at run time (serial.log), outcome by outcome, in order.
Usage: agree.py <realize.txt> <serial.log>"""
import re, sys
P = open(sys.argv[1]).read().splitlines()
L = open(sys.argv[2]).read().splitlines()
pred, run = [], []
for l in P:
    m = re.match(r"^predict: open #\d+ bits=\d+ -> ok rows=(\d+)$", l)
    if m: pred.append(("open", "ok", m.group(1))); continue
    m = re.match(r"^predict: open #\d+ bits=\d+ -> refused reason=(.+)$", l)
    if m: pred.append(("open", "refused", m.group(1))); continue
    m = re.match(r"^predict: (resolve|probe) foreign=(\S+) nid=(\S+) table=#\d+ -> bound row (\d+) interface=(\S+) export=(\S+)$", l)
    if m: pred.append((m.group(1), "bound", m.group(2), m.group(3), m.group(4), m.group(5), m.group(6))); continue
    m = re.match(r"^predict: (resolve|probe) foreign=(\S+) nid=(\S+) table=#\d+ -> refused missing=(.+) offered=\[(.*)\]$", l)
    if m: pred.append((m.group(1), "refused", m.group(2), m.group(3), m.group(4), m.group(5))); continue
    m = re.match(r"^predict: retarget (\S+) to=(\S+) -> ok rows=(\d+)$", l)
    if m: pred.append(("retarget", "ok", m.group(1), m.group(2), m.group(3))); continue
    m = re.match(r"^predict: retarget (\S+) to=(\S+) -> refused$", l)
    if m: pred.append(("retarget", "refused", m.group(1), m.group(2))); continue
    if l.startswith("predict:"): pred.append(("unparsed", l))
for l in L:
    m = re.match(r"^table: open rows=(\d+) nid_bits=\d+$", l)
    if m: run.append(("open", "ok", m.group(1))); continue
    m = re.match(r"^refused: row=\".*\" reason=(.+) other=\S+ phase=configure$", l)
    if m: run.append(("open", "refused", m.group(1))); continue
    m = re.match(r"^bound: foreign=(\S+) nid=(\S+) -> row (\d+) -> interface=(\S+) iid=\S+ -> export=(\S+) gen=\d+ arm=\S+ via=(\w+)$", l)
    if m: run.append((m.group(6), "bound", m.group(1), m.group(2), m.group(3), m.group(4), m.group(5))); continue
    m = re.match(r"^refused: foreign=(\S+) nid=(\S+) arm=\S+ phase=link missing=(.+) offered=\[(.*)\] via=(\w+)$", l)
    if m: run.append((m.group(5), "refused", m.group(1), m.group(2), m.group(3), m.group(4))); continue
    m = re.match(r"^retarget: interface=(\S+) -> export=(\S+) rows=(\d+) gen=\d+ \(NIDs unchanged\)$", l)
    if m: run.append(("retarget", "ok", m.group(1), m.group(2), m.group(3))); continue
    m = re.match(r"^refused: retarget (\S+) to=(\S+) reason=.+ phase=configure$", l)
    if m: run.append(("retarget", "refused", m.group(1), m.group(2))); continue
ok = pred == run and len(pred) > 0
print(f"predictions={len(pred)} run-time outcomes={len(run)}")
for i in range(max(len(pred), len(run))):
    a = pred[i] if i < len(pred) else None; b = run[i] if i < len(run) else None
    print(f"  {'=' if a == b else 'X'} {a}" + ("" if a == b else f"  vs run {b}"))
print("L1 PASS (build-time link phase agrees with the run)" if ok else "L1 FAIL"); sys.exit(0 if ok else 1)
