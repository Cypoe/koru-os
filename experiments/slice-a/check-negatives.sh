#!/usr/bin/env bash
# Compile-time gates for koruos/slice. Usage: check-negatives.sh <workdir from build-slice.sh>
set -u
cd "$1/koruos/slice/tests"; pass=1
want() { # file expected-substring
  rm -f output_emitted.zig
  koruc "$1" > "/tmp/slice-$1.log" 2>&1; rc=$?
  if [ $rc -ne 0 ] && grep -qF "$2" "/tmp/slice-$1.log"; then echo "REJECTED as expected: $1 :: $(grep -m1 -F "$2" /tmp/slice-$1.log)"
  else echo "UNEXPECTED: $1 exit=$rc"; pass=0; fi
}
rm -f output_emitted.zig
koruc control_minimal.k > /tmp/slice-control.log 2>&1 && test -s output_emitted.zig && echo "control compiles: control_minimal.k" || { echo "UNEXPECTED: control failed"; pass=0; }
want negative_start_unsealed.k   "expected 'koruos.slice:sealed' but got 'koruos.slice:staged!'"
want negative_grant_after_seal.k "expected 'koruos.slice:staged' but got 'koruos.slice:sealed!'"
want negative_reap_running.k     "expected 'koruos.slice:exited' but got 'koruos.slice:running!'"
want negative_child_leaked.k     "obligation <running!> was not discharged"
[ $pass = 1 ] && echo "SLICE-compile PASS" || echo "SLICE-compile FAIL"
