#!/usr/bin/env python3
"""gate-surf-wire — kauto scenario acceptance gate for the native compositor.

The 'kauto' shell scenario (shell.zig) self-drives kms -> kwin -> ksurf ->
kprog on the target and brackets the run with 'echo KSCEN-BEGIN' /
'echo KSCEN-DONE'. Console output mirrors to the UDP wire, so listener.log
carries the whole scenario as text. This gate slices the log between the
LAST begin/done pair and asserts, inside the slice:

  M1 program markers — the compiled Koru program ran and said so:
       'SURF LIVE 0 up'      (surface 0 opened + presented by prog.main)
       'SURF LIVE 1 up'      (surface 1)
       'SURF LIVE ... 2 surfaces open'   (~run summary; dash bytes vary)
       'kprog: program returned'          (dispatch survived prog.main)
       >= 2 'surf: open' provider markers
  M2 scenario completed — DONE marker present after BEGIN (a stalled
     scenario — e.g. kms hang — fails here, not silently passes).
  P1 compositor invariants — the slice is delegated to
     gate-perf-wire.py: cpu==0 everywhere, gpu-backed flips, advancing
     frames. This is the i915 tier: QEMU has no GPU and cannot pass P1;
     use --markers-only for QEMU dev runs of the mechanics.

Usage: gate-surf-wire.py <listener.log> [--markers-only] [--json]
Exit 0 = PASS, 1 = FAIL, 2 = usage.
"""
import re, sys, os, json, subprocess, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PERF_GATE = os.path.join(HERE, "gate-perf-wire.py")

BEGIN = "KSCEN-BEGIN"
DONE = "KSCEN-DONE"


def load(path):
    with open(path, "rb") as fh:
        return [ln.decode("latin1").rstrip("\n") for ln in fh]


def slice_scenario(lines):
    """Return (slice_lines, error). Slice = last BEGIN .. last DONE after it."""
    begin = None
    for i, ln in enumerate(lines):
        if BEGIN in ln:
            begin = i
    if begin is None:
        return None, f"no '{BEGIN}' marker — scenario never ran (or log predates kauto)"
    done = None
    for i in range(begin + 1, len(lines)):
        if DONE in lines[i]:
            done = i
    if done is None:
        return lines[begin:], f"'{DONE}' missing — scenario incomplete (stalled?)"
    return lines[begin:done + 1], None


def check_markers(slug):
    """slug = scenario slice lines. Returns (fails, stats)."""
    fails = []
    text = "\n".join(slug)
    stats = {}

    def has(s):
        return s in text

    checks = [
        ("M1a SURF LIVE 0 up", has("SURF LIVE 0 up")),
        ("M1b SURF LIVE 1 up", has("SURF LIVE 1 up")),
        ("M1c 2 surfaces open", bool(re.search(r"SURF LIVE.*2 surfaces open", text))),
        ("M1d kprog returned", has("kprog: program returned")),
    ]
    n_surf_open = len(re.findall(r"surf: open", text))
    stats["surf_open_markers"] = n_surf_open
    checks.append(("M1e surf: open x2", n_surf_open >= 2))
    for name, ok in checks:
        if not ok:
            fails.append(f"{name}: marker absent from scenario slice")
    stats["marker_lines"] = sum(1 for ln in slug if ln.strip())
    return fails, stats


def check_perf(slug):
    """Delegate the slice to gate-perf-wire.py via a temp file."""
    if not os.path.exists(PERF_GATE):
        return [f"P1 perf: gate-perf-wire.py not found at {PERF_GATE}"], ""
    with tempfile.NamedTemporaryFile("w", suffix=".log", delete=False) as tf:
        tf.write("\n".join(slug) + "\n")
        tmp = tf.name
    try:
        p = subprocess.run([sys.executable, PERF_GATE, tmp],
                           capture_output=True, text=True)
        out = (p.stdout + p.stderr).rstrip()
        return ([] if p.returncode == 0 else ["P1 perf: gate-perf-wire FAILED on slice"]), out
    finally:
        os.unlink(tmp)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    markers_only = "--markers-only" in sys.argv
    if not args:
        print(__doc__.strip().splitlines()[-1]); return 2
    lines = load(args[0])
    slug, err = slice_scenario(lines)
    if slug is None:
        print(f"GATE FAIL: {err}"); return 1

    fails, stats = check_markers(slug)
    if err:
        fails.append(f"M2 scenario: {err}")

    perf_out = ""
    if not markers_only:
        pfails, perf_out = check_perf(slug)
        fails.extend(pfails)

    rep = {"slice_lines": stats.get("marker_lines", len(slug)),
           "surf_open_markers": stats.get("surf_open_markers", 0),
           "scenario_complete": err is None,
           "perf_checked": not markers_only,
           "failures": fails}
    if "--json" in sys.argv:
        print(json.dumps(rep, indent=2))
    else:
        print(f"gate-surf-wire: scenario slice = {len(slug)} wire lines "
              f"({stats.get('surf_open_markers', 0)} 'surf: open' markers)")
        if err:
            print(f"  WARN {err}")
        for f in fails:
            print(f"  FAIL {f}")
        if perf_out:
            print("  --- gate-perf-wire on slice ---")
            for ln in perf_out.splitlines():
                print(f"  {ln}")
        if not fails:
            missing = " (markers-only)" if markers_only else ""
            print(f"GATE PASS{missing}")
        else:
            print("GATE FAIL")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
