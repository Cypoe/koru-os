#!/usr/bin/env bash
# Compile-time gates for koruos/spawn (DESIGN-0001 §8.6.6). Usage: check-negatives.sh <workdir from build-spawn.sh>
# "compiles" = koruc emits output_emitted.zig and the host link fails only on ukplat_monotonic_clock.
set -u
cd "$1/koruos/spawn/tests"; pass=1
compiles() { rm -f output_emitted.zig; koruc "$1" > "/tmp/spawn-$1.log" 2>&1; rc=$?
  [ -s output_emitted.zig ] && { [ $rc -eq 0 ] || [ "$(grep -c 'error' "/tmp/spawn-$1.log")" = "$(grep -c 'undefined symbol: ukplat_monotonic_clock' "/tmp/spawn-$1.log")" ]; }; }
want() { rm -f output_emitted.zig; koruc "$1" > "/tmp/spawn-$1.log" 2>&1; rc=$?
  if [ $rc -ne 0 ] && grep -qF "$2" "/tmp/spawn-$1.log"; then echo "REJECTED as expected: $1 :: $(grep -m1 -F "$2" /tmp/spawn-$1.log)"
  else echo "UNEXPECTED: $1 exit=$rc"; pass=0; fi; }
for c in control_minimal.k control_abandon.k; do compiles $c && echo "control compiles: $c" || { echo "UNEXPECTED: control failed: $c"; pass=0; }; done
want negative_start_unsealed.k   "expected 'koruos.spawn:sealed' but got 'koruos.spawn:staged!'"
want negative_grant_after_seal.k "expected 'koruos.spawn:staged' but got 'koruos.spawn:sealed!'"
want negative_reap_running.k     "expected 'koruos.spawn:exited' but got 'koruos.spawn:running!'"
want negative_child_leaked.k     "obligation <running!> was not discharged"
[ $pass = 1 ] && echo "SPAWN-compile PASS" || echo "SPAWN-compile FAIL"
