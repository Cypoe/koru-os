#!/usr/bin/env bash
# Compile-time gates for koruos/nid. Usage: check-negatives.sh <workdir from build-nid.sh>
# "compiles" = koruc emits output_emitted.zig and the host link fails only on the Unikraft
# symbol ukplat_monotonic_clock (expected: the host has no Unikraft platform).
set -u
cd "$1/koruos/nid/tests"; pass=1
compiles() { rm -f output_emitted.zig; koruc "$1" > "/tmp/nid-$1.log" 2>&1; rc=$?
  [ -s output_emitted.zig ] && { [ $rc -eq 0 ] || [ "$(grep -c 'error' "/tmp/nid-$1.log")" = "$(grep -c 'undefined symbol: ukplat_monotonic_clock' "/tmp/nid-$1.log")" ]; }; }
want() { # file expected-substring
  rm -f output_emitted.zig; koruc "$1" > "/tmp/nid-$1.log" 2>&1; rc=$?
  if [ $rc -ne 0 ] && grep -qF "$2" "/tmp/nid-$1.log"; then echo "REJECTED as expected: $1 :: $(grep -m1 -F "$2" /tmp/nid-$1.log)"
  else echo "UNEXPECTED: $1 exit=$rc"; pass=0; fi
}
auto() { # file tor-that-must-be-emitted
  if compiles "$1" && grep -q "koru_nid.$2_event.handler" output_emitted.zig; then echo "AUTO-DISCHARGED as expected: $1 (koruc emitted $2)"
  else echo "UNEXPECTED: $1"; pass=0; fi
}
compiles control_minimal.k && echo "control compiles: control_minimal.k" || { echo "UNEXPECTED: control failed"; pass=0; }
want negative_call_after_release.k  "error[KORU030]: Use-after-discharge: binding 'r.b' was already discharged"
want negative_resolve_after_close.k "error[KORU030]: Use-after-discharge: binding 't' was already discharged"
auto autodischarge_binding_release.k release
[ $pass = 1 ] && echo "NID-compile PASS" || echo "NID-compile FAIL"
