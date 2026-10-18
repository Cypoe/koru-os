#!/usr/bin/env bash
# One boot per case: /bin/busybox sh -c '<case>'. Prints PASS/CRASH plus the first output lines.
HERE=$(cd "$(dirname "$0")" && pwd)
while IFS= read -r c; do
  [ -z "$c" ] && continue
  s=$(date +%s.%N); out=$("$HERE/qemu.sh" "/bin/busybox sh -c '$c'" </dev/null 2>&1 | tr -d '\r' | sed -n '/Powered by/,$p' | sed 1d); e=$(date +%s.%N)
  if grep -q "Unikraft Crash" <<<"$out"; then st=CRASH; else st=RAN; fi
  printf '== [%s] %s  (wall %.3fs)\n' "$st" "$c" "$(echo "$e - $s" | bc)"
  grep -av "CRIT:   *[a-z0-9]*:" <<<"$out" | head -3 | cut -c1-160
done <<'CASES'
echo M3-HELLO
uname -a
date; date; id
wc -c /bin/busybox
sha256sum /bin/busybox
mkdir /tmp/d && echo ok
ls /
ls /bin/a*
ls /bin > /tmp/l; wc -l /tmp/l
ls -1 / > /tmp/o; cat /tmp/o
true | true
echo x | cat
seq 3 | wc -l
cat /proc/version
true | true; echo rc=$?
echo hello | tr a-z A-Z | wc -c
x=$(echo sub); echo got:$x
ls /bin | grep -c .
sh -c "exit 3"; echo rc=$?
/bin/vrepro 0
/bin/vrepro 1
/bin/vrepro 2
/bin/vrepro 3
CASES
