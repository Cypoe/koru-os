#!/usr/bin/env bash
# check-realize.sh — the realize contract, enforced.
#
# Controls must bind; negatives must refuse with a named line; the native
# provider must bind iff imported. Every expectation greps the emitted
# artifacts and the command's own output — a green run is a claim that the
# gate still says what the fixtures say it says. Runs on the Windows box;
# needs koruc + zig (see AGENTS.md). QEMU-image regressions live in the
# other scripts here — this is the declaration-phase tier.
set -u

# Pinned: see build-native.sh — koru@aaa64576c worktree while ccomp's
# zig emitter leaks |c bodies into zig output.
KORUC="${KORUC:-/w/src/koru-aaa6457/zig-out/bin/koruc.exe}"
KORULIBS="${KORULIBS:-/w/src/koru-libs}"
export PATH="/w/tools/zig-0.15.1:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$(cygpath -m "$ROOT/koru/realize/tests" 2>/dev/null || echo "$ROOT/koru/realize/tests")"
LIBS="$(cygpath -m "$KORULIBS" 2>/dev/null || echo "$KORULIBS")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; failn=0
ok()  { pass=$((pass+1));  echo "ok   $1"; }
bad() { failn=$((failn+1)); echo "FAIL $1"; }

# stage <name>: substitutes {{ ENTRY }} and the unikraft alias into $WORK/<name>.k
stage() {
    sed -e "s|{{ ENTRY }}|$FIX|g" \
        -e "s|unikraft: .*|unikraft: $LIBS/unikraft|" \
        "$ROOT/koru/realize/tests/$1.k" > "$WORK/$1.k"
}

# run_k <name> [realize args...]: compile, capture output+exit code
run_k() {
    local name="$1"; shift
    (cd "$WORK" && "$KORUC" "$WORK/$name.k" realize "$@" > "$WORK/$name.out" 2>&1)
    RC=$?
}
# expect_grep <name> <pattern>: the run's output or realize.txt must contain it
expect_grep() {
    grep -q "$2" "$WORK/$1.out" 2>/dev/null && return 0
    grep -q "$2" "$WORK/realize.txt" 2>/dev/null && return 0
    bad "$1: expected /$2/"; sed -n '1,8p' "$WORK/$1.out" | sed 's/^/     /'
    return 1
}

cd "$WORK"

# --- controls -------------------------------------------------------------
stage control_rowed
run_k control_rowed gen
if [ "$RC" -eq 0 ] && [ -f "$WORK/Kraftfile" ]; then ok "control_rowed binds"
else bad "control_rowed (rc=$RC, Kraftfile missing)"; fi
rm -f "$WORK"/Kraftfile "$WORK"/Makefile.uk "$WORK"/realize.txt

# --- negatives ------------------------------------------------------------
stage negative_unrowed
run_k negative_unrowed gen
if [ "$RC" -ne 0 ] && [ ! -f "$WORK/Kraftfile" ] \
   && grep -q "missing=realize row" "$WORK/realize.txt" 2>/dev/null; then ok "unrowed refuses by name"
else bad "negative_unrowed (rc=$RC)"; fi

stage negative_contradict
run_k negative_contradict gen
if [ "$RC" -ne 0 ] && [ ! -f "$WORK/Kraftfile" ] \
   && grep -q "contradicts derived" "$WORK/realize.txt" 2>/dev/null; then ok "contradict refuses"
else bad "negative_contradict (rc=$RC)"; fi

stage negative_badrow
run_k negative_badrow gen
if [ "$RC" -ne 0 ] && [ ! -f "$WORK/Kraftfile" ] \
   && grep -q 'lacks "arm" or "mechanism"' "$WORK/realize.txt" 2>/dev/null; then ok "badrow refuses naming the field"
else bad "negative_badrow (rc=$RC)"; fi

# --- native provider: binds iff imported -----------------------------------
cat > "$WORK/tnat.k" <<EOF
std/compiler:paths { koruos: $(cygpath -m "$ROOT/koru" 2>/dev/null || echo "$ROOT/koru") }
import koruos/native
import koruos/realize
import std/io
std/io:print.ln("x")
EOF
cat > "$WORK/tnoimp.k" <<EOF
std/compiler:paths { koruos: $(cygpath -m "$ROOT/koru" 2>/dev/null || echo "$ROOT/koru") }
import koruos/realize
import std/io
std/io:print.ln("x")
EOF

run_k tnat gen --arm koru-native
if [ -f "$WORK/manifest-koru-native.txt" ] \
   && grep -q "bind: koru.runtime -> native-runtime" "$WORK/manifest-koru-native.txt" \
   && grep -q "bind: std.io:print -> native-runtime" "$WORK/manifest-koru-native.txt"; then
    ok "koru-native binds runtime+print via koruos/native"
else bad "tnat native (rc=$RC)"; fi

# the verdicts must also land in the witness-shaped corpus, and the marks
# must name the *bind's* provenance (koruos/native), not just the row's
if grep -q 'admission","koru.runtime","koru-native<-native-runtime","bound".*bind_by=koruos.native' \
   "$WORK/tnat.marks" 2>/dev/null \
   && grep -q 'admission","std.io:print","koru-native<-native-runtime","bound"' \
   "$WORK/tnat.marks"; then
    ok "verdicts committed in @witness mark shape"
else bad "tnat.marks missing/misattributed"; fi
rm -f "$WORK"/manifest-*.txt "$WORK"/realize.txt "$WORK"/*.marks

run_k tnoimp gen --arm koru-native
if [ "$RC" -ne 0 ] && [ ! -f "$WORK/manifest-koru-native.txt" ] \
   && grep -q "missing=binding" "$WORK/realize.txt" 2>/dev/null \
   && grep -q 'admission","koru.runtime","koru-native<-none","refused"' \
      "$WORK/tnoimp.marks" 2>/dev/null; then
    ok "koru-native refuses without the provider import (mark + line)"
else bad "tnoimp native (rc=$RC)"; fi

# a malformed declaration must refuse in both surfaces (text + marks)
run_k negative_badrow gen
if grep -q 'declaration","rzfix.badrow","decl<-parsed","refused","binds-0-lacks-arm-or-mechanism"' \
   "$WORK/negative_badrow.marks" 2>/dev/null; then
    ok "declaration refusals committed as marks"
else bad "badrow mark missing"; fi

# the native provider binds the clock/entropy lifts it serves — boot_silo
# with koruos/native imported must bind all 11 silo tors on koru-native
FIX_SILO="$(cygpath -m "$ROOT/koru/silo/tests" 2>/dev/null || echo "$ROOT/koru/silo/tests")"
sed -e "s|{{ ENTRY }}|$FIX_SILO|g" \
    -e "s|unikraft: .*|unikraft: $LIBS/unikraft|" \
    -e '0,/^import /s//import koruos\/native\nimport /' \
    "$ROOT/koru/silo/tests/boot_silo.k" > "$WORK/tsilo_nat.k"
run_k tsilo_nat gen --arm koru-native
if [ -f "$WORK/manifest-koru-native.txt" ] \
   && grep -q "bind: koruos.silo -> native-runtime" "$WORK/manifest-koru-native.txt" \
   && grep -q 'admission","koruos.silo:open","koru-native<-native-runtime","bound".*bind_by=koruos.silo' \
      "$WORK/tsilo_nat.marks" 2>/dev/null; then
    ok "koru-native binds the silo lift (entropy+heap+console)"
else bad "tsilo_nat native (rc=$RC)"; fi
# the spawn lift binds at its DECLARED rung: rung 0/1 (entry-function
# children run to completion inside start, seam-enforced bag) needs only
# heap+clock+console — all 12 tors are served by the one module row, and
# the rung caveat must ride the bind deltas (no MMU isolation claimed)
FIX_SPAWN="$(cygpath -m "$ROOT/koru/spawn/tests" 2>/dev/null || echo "$ROOT/koru/spawn/tests")"
sed -e "s|{{ ENTRY }}|$FIX_SPAWN|g" \
    -e "s|unikraft: .*|unikraft: $LIBS/unikraft|" \
    -e '0,/^import /s//import koruos\/native\nimport /' \
    "$ROOT/koru/spawn/tests/boot_spawn.k" > "$WORK/tspawn_nat.k"
run_k tspawn_nat gen --arm koru-native
if [ -f "$WORK/manifest-koru-native.txt" ] \
   && grep -q "bind: koruos.spawn -> native-runtime" "$WORK/manifest-koru-native.txt" \
   && grep -q "rung:0/1" "$WORK/manifest-koru-native.txt" \
   && [ "$(grep -c 'admission","koruos.spawn:[a-z-]*","koru-native<-native-runtime","bound"' "$WORK/tspawn_nat.marks" 2>/dev/null)" -eq 12 ]; then
    ok "koru-native binds all 12 spawn tors at declared rung 0/1"
else bad "tspawn_nat native (rc=$RC, bound=$(grep -c 'koruos.spawn:.*bound' "$WORK/tspawn_nat.marks" 2>/dev/null))"; fi
rm -f "$WORK"/manifest-*.txt "$WORK"/realize.txt "$WORK"/*.marks

# --- matrix: the printed projection must re-decide from the catalog data ---
run_k tnat matrix
if [ -f "$WORK/tnat.marks" ] \
   && grep -q 'catalog","koru.runtime","row<-declared","listed"' "$WORK/tnat.marks" \
   && grep -q 'projection","koru-native","matrix<-catalog","holds","bound=' "$WORK/tnat.marks"; then
    ok "matrix mints catalog+projection marks"
else bad "matrix marks missing"; fi

# the Lean checker recounts the projection over the committed catalog —
# a missing toolchain is failure, never a skip
WITNESS_DIR="${KORU_WITNESS:-/w/src/koru/verify/witness}"
LEAN="${KORU_LEAN:-$HOME/.elan/toolchains/leanprover--lean4---v4.31.0/bin/lean.exe}"
if [ ! -x "$LEAN" ]; then
    for cand in "$HOME"/.elan/toolchains/leanprover--lean4---v*/bin/lean.exe; do
        [ -x "$cand" ] && LEAN="$cand" && break
    done
fi
if [ -x "$LEAN" ] && [ -f "$WITNESS_DIR/WitnessCheck.lean" ] \
   && (cd "$WITNESS_DIR" && "$LEAN" --run WitnessCheck.lean "$WORK/tnat.marks" > "$WORK/lean_matrix.out" 2>&1) \
   && grep -q "conformance (all must match): .*0 bad" "$WORK/lean_matrix.out"; then
    ok "Lean recounts the projection over committed catalog marks"
else bad "Lean projection re-decision failed (lean=$LEAN)"; sed -n '1,6p' "$WORK/lean_matrix.out" 2>/dev/null | sed 's/^/     /'; fi

if [ -f "$WORK/rows.json" ] && [ -f "$WORK/arm-matrix.txt" ]; then
    if python - "$WORK" <<'PYEOF'
import json, re, sys, pathlib
w = pathlib.Path(sys.argv[1])
rows = json.loads((w / "rows.json").read_text())
arms = rows["arms"]
bound = {a: sum(1 for r in rows["rows"] if any(b["arm"] == a for b in r["binds"]))
         for a in arms}
matrix = (w / "arm-matrix.txt").read_text()
ok = all(f"{a}: {n}/{len(rows['rows'])}" in matrix for a, n in bound.items())
sys.exit(0 if ok else 1)
PYEOF
    then ok "matrix re-decides from rows.json"
    else bad "matrix disagrees with independent recount"; fi
else bad "matrix artifacts missing"; fi

echo "---"
echo "check-realize: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
