#!/usr/bin/env python3
"""gate-perf-wire — mechanical oracle for the i915 GPU compositor, parsed
from the UDP telemetry listener.log. This is the acceptance gate that turns
'it looked smooth on the panel' into a rerunnable pass/fail.

Each `perf` line is one measurement window:
    perf f=<flips> ... gpu=<gpu-composited> cpu=<cpu-fallback> adv=<advanced>
         i=<min/max/avg flip-interval TSC> g=<>100ms gaps> fb=<flush bytes> ...

Invariants asserted (the claims we have been eyeballing in prose):
  I1 cpu-zero      — cpu==0 on EVERY line: no frame ever fell back to CPU
                     compositing. This is the 'GPU-backed, not software'
                     claim; a single cpu>0 is a hard fail.
  I2 gpu-backed    — on active windows (f>0), gpu>0 and gpu>=f-1: the flips
                     were GPU-composited, not hollow/CPU.
  I3 advancing     — on SUSTAINED windows (f >= --min-f, default 8), adv>0:
                     real activity carries new pixels. Small-f windows are
                     micro-activity (startup, cursor jitter, single events)
                     where adv=0 is legitimate — counted, not gated.
  I4 present       — at least one active window exists to judge (a log with
                     only idle f=0 lines cannot pass — nothing was measured).

Usage: gate-perf-wire.py <listener.log> [--tail N] [--json]
Exit 0 = all invariants held over the sampled windows; 1 = a claim broke.
"""
import re, sys, json

KV = re.compile(r"([A-Za-z_]+)=(-?\d+)")

def parse(path, tail):
    rows = []
    with open(path, "rb") as fh:
        for raw in fh:
            line = raw.decode("latin1")
            i = line.find("perf f=")
            if i < 0:
                continue
            # fields run to end-of-line / closing quote; key=value pairs only
            d = {k: int(v) for k, v in KV.findall(line[i:])}
            need = ("f", "gpu", "cpu", "adv", "fb")
            if all(k in d for k in need):
                rows.append(d)
    return rows[-tail:] if tail else rows

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    tail = None
    if "--tail" in sys.argv:
        tail = int(sys.argv[sys.argv.index("--tail") + 1])
    min_f = 8
    if "--min-f" in sys.argv:
        min_f = int(sys.argv[sys.argv.index("--min-f") + 1])
    if not args:
        print(__doc__.strip().splitlines()[-1]); return 2
    rows = parse(args[0], tail)
    if not rows:
        print("GATE FAIL: no perf lines found — nothing measured"); return 1

    active = [r for r in rows if r["f"] > 0]
    idle   = [r for r in rows if r["f"] == 0]
    sustained = [r for r in active if r["f"] >= min_f]
    micro = [r for r in active if r["f"] < min_f]

    fails = []
    # I1 — cpu==0 everywhere (idle lines included: even idle must not CPU-fallback)
    bad_cpu = [r for r in rows if r["cpu"] != 0]
    if bad_cpu:
        fails.append(f"I1 cpu-zero: {len(bad_cpu)} line(s) with cpu>0 "
                     f"(max cpu={max(r['cpu'] for r in bad_cpu)})")
    # I2 — gpu-backed on active windows
    bad_gpu = [r for r in active if not (r["gpu"] > 0 and r["gpu"] >= r["f"] - 1)]
    if bad_gpu:
        fails.append(f"I2 gpu-backed: {len(bad_gpu)}/{len(active)} active window(s) "
                     f"not GPU-composited (e.g. f={bad_gpu[0]['f']} gpu={bad_gpu[0]['gpu']})")
    # I3 — advancing on SUSTAINED windows (real activity must move pixels)
    bad_adv = [r for r in sustained if r["adv"] == 0]
    if bad_adv:
        fails.append(f"I3 advancing: {len(bad_adv)}/{len(sustained)} sustained "
                     f"window(s) (f>={min_f}) with adv=0 (hollow flips); "
                     f"{len(micro)} micro window(s) exempt")
    # I4 — something was actually measured
    if not active:
        fails.append("I4 present: zero active windows (f>0) — idle-only log proves nothing")

    # stats for the report
    tf = sum(r["f"] for r in rows); tg = sum(r["gpu"] for r in rows)
    tfb = sum(r["fb"] for r in rows); maxfb = max(r["fb"] for r in rows)
    advs = [r["adv"] for r in active]

    rep = {
        "windows": len(rows), "active": len(active), "sustained": len(sustained),
        "micro": len(micro), "idle": len(idle),
        "flips": tf, "gpu_flips": tg, "cpu_fallback": sum(r["cpu"] for r in rows),
        "flush_bytes": tfb, "max_window_flush": maxfb,
        "adv_min": min(advs) if advs else 0, "adv_max": max(advs) if advs else 0,
        "invariants": {"I1_cpu_zero": not bad_cpu, "I2_gpu_backed": not bad_gpu,
                       "I3_advancing": not bad_adv, "I4_present": bool(active)},
        "failures": fails,
    }
    if "--json" in sys.argv:
        print(json.dumps(rep, indent=2))
    else:
        print(f"gate-perf-wire: {len(rows)} windows ({len(active)} active "
              f"[{len(sustained)} sustained, {len(micro)} micro], {len(idle)} idle)")
        print(f"  flips={tf} gpu={tg} cpu_fallback={rep['cpu_fallback']} "
              f"flush={tfb/1e6:.1f}MB max_win={maxfb/1e6:.2f}MB")
        print(f"  adv range on active: {rep['adv_min']}..{rep['adv_max']}")
        for k, v in rep["invariants"].items():
            print(f"  {k}: {'PASS' if v else 'FAIL'}")
        for f in fails:
            print(f"  FAIL {f}")
        print("GATE " + ("PASS" if not fails else "FAIL"))
    return 0 if not fails else 1

if __name__ == "__main__":
    sys.exit(main())
