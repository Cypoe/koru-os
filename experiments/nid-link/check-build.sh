#!/usr/bin/env bash
# Build-time gates (ACCEPTANCE.md L2): required imports that cannot bind are refused by
# `koruc <file> realize gen` before an image exists. Usage: check-build.sh <koru-libs> <workdir>
set -u
LIBS=$1; W=$2; REPO=$(cd "$(dirname "$0")/../.." && pwd); pass=1
rm -rf "$W"; mkdir -p "$W/koruos"; cp -R "$REPO/koru/nid" "$REPO/koru/realize" "$W/koruos/"; cp -R "$LIBS/unikraft" "$W/"
cd "$W/koruos/nid/tests"
gate() { # file ok|refused substring
  rm -rf Kraftfile realize.txt .unikraft; koruc "$1" realize gen > "$1.log" 2>&1; rc=$?
  ok=0
  if [ "$2" = ok ]; then [ $rc -eq 0 ] && [ -s Kraftfile ] && ok=1
  else [ $rc -ne 0 ] && [ ! -e Kraftfile ] && [ ! -e .unikraft ] && grep -q "refusal(s), no Kraftfile written" "$1.log" && ok=1; fi
  grep -qF -- "$3" realize.txt 2>/dev/null || ok=0
  if [ $ok = 1 ]; then echo "AS EXPECTED: $1 exit=$rc kraftfile=$([ -e Kraftfile ] && echo yes || echo no) :: $(grep -m1 -F -- "$3" realize.txt)"
  else echo "UNEXPECTED: $1 exit=$rc"; tail -3 "$1.log"; pass=0; fi
}
gate build_control.k        ok      "predict: resolve foreign=c/libc/1/fputs nid=op2qbSMIgP4 table=#0 -> bound row 0 interface=koruos.console.write@1 export=console_com1_v1:write"
gate build_probe_unbound.k  ok      "predict: probe foreign=c/libc/1/puts nid=WXSxCpbNP58 table=#0 -> refused missing=correspondence row offered=[none]"
gate build_unbound.k        refused "refused: foreign=c/libc/1/puts nid=WXSxCpbNP58 arm=unikraft/qemu-x86_64 phase=configure missing=correspondence row offered=[none] via=resolve (required)"
gate build_wrong_version.k  refused "refused: foreign=c/libc/2/fputs nid=AaVbDaC0b6I arm=unikraft/qemu-x86_64 phase=configure missing=correspondence row offered=[c/libc/1/fputs] via=resolve (required)"
gate build_refused_table.k  refused "refused: foreign=c/libc/1/fputs arm=unikraft/qemu-x86_64 phase=configure missing=table (create would overwrite a bound foreign name (use evolve)) via=resolve (required)"
gate build_collision.k      refused "missing=unique nid (collides with a row for another foreign name) offered=[none] via=resolve (required)"
[ $pass = 1 ] && echo "L2 PASS" || echo "L2 FAIL"
