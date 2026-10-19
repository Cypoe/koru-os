#!/usr/bin/env bash
# Configure-phase gates for koruos/realize (ACCEPTANCE.md R6).
# Usage: check-negatives.sh <koru-libs @ ff5cb559> <workdir>
set -u
LIBS=$1; W=$2; REPO=$(cd "$(dirname "$0")/../.." && pwd); pass=1
rm -rf "$W"; mkdir -p "$W/koruos"; cp -R "$REPO/koru/realize" "$W/koruos/"; cp -R "$LIBS/unikraft" "$W/"
cd "$W/koruos/realize/tests"
gate() { # file ok|refused want-substring   (koruc reports a refusing command as exit 1; realize itself exits 3)
  rm -f Kraftfile realize.txt; koruc "$1" realize gen > "$1.log" 2>&1; rc=$?
  ok=0
  if [ "$2" = ok ]; then [ $rc -eq 0 ] && [ -s Kraftfile ] && ok=1
  else [ $rc -ne 0 ] && [ ! -e Kraftfile ] && grep -q "refusal(s), no Kraftfile written" "$1.log" && ok=1; fi
  grep -q -- "$3" realize.txt 2>/dev/null || ok=0
  if [ $ok = 1 ]; then echo "AS EXPECTED: $1 exit=$rc :: $(grep -m1 -- "$3" realize.txt)"
  else echo "UNEXPECTED: $1 exit=$rc kraftfile=$([ -e Kraftfile ] && echo yes || echo no)"; tail -5 "$1.log"; pass=0; fi
}
gate control_rowed.k        ok "CONFIG_STACK_SIZE_PAGE_ORDER="
gate negative_unrowed.k     refused "refused: interface=rzfix.unrowed:census"
gate negative_contradict.k  refused "refused: author line CONFIG_LIBUKSCHEDCOOP: 'y' contradicts derived"
[ $pass = 1 ] && echo "R6 PASS" || echo "R6 FAIL"
