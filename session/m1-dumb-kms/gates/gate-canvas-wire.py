#!/usr/bin/env python3
"""gate-canvas-wire — kauto acceptance gate for the native canvas app.

The canvas smoke app (oshun canvas/tests/native_smoke.k, --build=koru-native)
runs inside the kauto scenario at kprog: opens a 320x200 surface, clears to
0x0f1424, paints a rounded panel + 'KORU NATIVE' text + a clipped rect for
240 frames, and emits window.snap KSNAP pixel samples on the wire every
frame. This gate slices listener.log between the LAST KSCEN-BEGIN/DONE pair
and asserts, inside the slice:

  C1 lifecycle    — 'native metal: frames done, window closed' and
                    'kprog: program returned' present.
  C2 snap oracle  — >=1 KSNAP marker; the LAST one's 12-sample grid equals
                    the expected pixel map exactly (bg 000f1424, panel
                    00292e42, rect 00e66633). Wrong color at a coord = FAIL
                    naming the coord — this is the falsifying check, not a
                    presence check.
  C3 wire hygiene — no 'marker too long' refusals in the slice (the 400B
                    datagram cap silently ate KSNAP once; regressions here
                    are silent by design).
  P1 compositor   — delegated to gate-perf-wire.py: cpu==0 on every active
                    window, gpu-backed flips. i915 tier: QEMU-fb cannot
                    pass P1; use --markers-only for QEMU dev runs.

Usage: gate-canvas-wire.py <listener.log> [--markers-only] [--json]
Exit 0 = PASS, 1 = FAIL, 2 = usage.
"""
import re, sys, os, json, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
PERF_GATE = os.path.join(HERE, "gate-perf-wire.py")

BEGIN = "KSCEN-BEGIN"
DONE = "KSCEN-DONE"

# Expected 4x3 grid over the 320x200 surface: sx = gx*80, sy = gy*~66.
# Verified on T590 silicon AND QEMU — identical values both places.
EXPECTED = {
    (0, 0): "000f1424", (80, 0): "000f1424", (160, 0): "000f1424", (240, 0): "000f1424",
    (0, 66): "000f1424", (80, 66): "00292e42", (160, 66): "00292e42", (240, 66): "00292e42",
    (0, 133): "000f1424", (80, 133): "00e66633", (160, 133): "000f1424", (240, 133): "000f1424",
}

SNAP_RE = re.compile(r"SNAP (\d+),(\d+) ([0-9a-fA-F]{8})")


def load(path):
    with open(path, "rb") as fh:
        return [ln.decode("latin1").rstrip("\n") for ln in fh]


def slice_scenario(lines):
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
    fails = []
    stats = {}
    text = "\n".join(slug)

    # C1 lifecycle
    if "native metal: frames done, window closed" not in text:
        fails.append("C1a 'native metal: frames done' absent — app did not complete")
    if "kprog: program returned" not in text:
        fails.append("C1b 'kprog: program returned' absent — dispatch did not survive")

    # C2 snap oracle — parse every KSNAP payload, keep the last full grid
    grids = []
    for ln in slug:
        if "KSNAP" not in ln:
            continue
        samples = {}
        for m in SNAP_RE.finditer(ln):
            samples[(int(m.group(1)), int(m.group(2)))] = m.group(3).lower()
        if samples:
            grids.append(samples)
    stats["ksnap_lines"] = len(grids)
    if not grids:
        fails.append("C2a no KSNAP sample grids on the wire — window.snap emitted nothing")
    else:
        last = grids[-1]
        stats["ksnap_samples"] = len(last)
        bad = [(c, last.get(c), want) for c, want in EXPECTED.items()
               if last.get(c) != want]
        # coords the app drew but the grid didn't expect are informational only
        if bad:
            detail = ", ".join(f"({x},{y})={got or 'missing'}!={want}"
                               for (x, y), got, want in bad[:4])
            fails.append(f"C2b last KSNAP grid mismatch: {detail}")
        # consistency: every grid identical (deterministic rasterizer)
        first = grids[0]
        drift = sum(1 for g in grids[1:] if g != first)
        stats["ksnap_drift"] = drift
        if drift:
            fails.append(f"C2c {drift}/{len(grids) - 1} KSNAP grids differ from the first — surface not stable")

    # C3 wire hygiene — the 400B cap refuses silently; any refusal in-slice
    # means a marker outgrew the datagram again.
    refused = sum(1 for ln in slug if "marker too long" in ln)
    stats["marker_refusals"] = refused
    if refused:
        fails.append(f"C3 {refused} 'marker too long' refusals in slice — a wire payload exceeds the 400B cap")

    return fails, stats


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    markers_only = "--markers-only" in sys.argv
    as_json = "--json" in sys.argv
    if len(args) != 1:
        print(__doc__.strip().splitlines()[-1]); return 2

    lines = load(args[0])
    slug, err = slice_scenario(lines)
    if err:
        print(f"GATE FAIL: {err}"); return 1

    fails, stats = check_markers(slug)
    p1 = None
    if not markers_only and os.path.exists(PERF_GATE):
        with open(os.path.join(HERE, "_canvas_slice.log"), "w") as fh:
            fh.write("\n".join(slug) + "\n")
        rc = subprocess.call([sys.executable, PERF_GATE,
                              os.path.join(HERE, "_canvas_slice.log")])
        p1 = (rc == 0)
        if not p1:
            fails.append("P1 gate-perf-wire failed on the scenario slice")
        os.unlink(os.path.join(HERE, "_canvas_slice.log"))

    result = {
        "gate": "canvas-wire", "pass": not fails,
        "markers_only": markers_only, "p1": p1, **stats,
        "fails": fails,
    }
    if as_json:
        print(json.dumps(result, indent=2))
    else:
        for f in fails:
            print(f"  FAIL {f}")
        if not fails:
            print(f"gate-canvas-wire: PASS — {stats.get('ksnap_lines', 0)} KSNAP grids, "
                  f"{stats.get('ksnap_drift', 0)} drift, {stats.get('marker_refusals', 0)} refusals"
                  + (" (markers-only)" if markers_only else ""))
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main())
