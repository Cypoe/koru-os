#!/usr/bin/env bash
# Compile-time gates for koruos/silo. Usage: check-negatives.sh <workdir from build-image.sh>
set -u
cd "$1/koruos/silo/tests"; pass=1
want() { # file expected-substring
  koruc "$1" > "/tmp/ds0-$1.log" 2>&1; rc=$?
  if [ $rc -ne 0 ] && grep -q "$2" "/tmp/ds0-$1.log"; then echo "REJECTED as expected: $1 :: $(grep -m1 "$2" /tmp/ds0-$1.log)"
  else echo "UNEXPECTED: $1 exit=$rc"; pass=0; fi
}
auto() { # file tor-that-must-be-emitted
  koruc "$1" > "/tmp/ds0-$1.log" 2>&1; rc=$?
  if [ $rc -eq 0 ] && grep -q "koru_silo.$2_event.handler" output_emitted.zig; then echo "AUTO-DISCHARGED as expected: $1 (koruc emitted $2)"
  else echo "UNEXPECTED: $1 exit=$rc"; pass=0; fi
}
koruc control_minimal.k > /tmp/ds0-control.log 2>&1 && echo "control compiles: control_minimal.k" || { echo "UNEXPECTED: control failed"; pass=0; }
want negative_call_unbound.k        "expected 'koruos.silo:bound' but got 'koruos.silo:minted!'"
want negative_call_after_revoked.k  "expected 'koruos.silo:bound' but got 'koruos.silo:revoked!'"
want negative_bind_twice.k          "expected 'koruos.silo:minted' but got 'koruos.silo:bound!'"
auto autodischarge_silo_close.k     close
auto autodischarge_handle_release.k release
[ $pass = 1 ] && echo "DS0-compile PASS" || echo "DS0-compile FAIL"
