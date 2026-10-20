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

KORUC="${KORUC:-/w/src/koru/zig-out/bin/koruc.exe}"
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
rm -f "$WORK"/manifest-*.txt "$WORK"/realize.txt

run_k tnoimp gen --arm koru-native
if [ "$RC" -ne 0 ] && [ ! -f "$WORK/manifest-koru-native.txt" ] \
   && grep -q "missing=binding" "$WORK/realize.txt" 2>/dev/null; then
    ok "koru-native refuses without the provider import"
else bad "tnoimp native (rc=$RC)"; fi

echo "---"
echo "check-realize: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
