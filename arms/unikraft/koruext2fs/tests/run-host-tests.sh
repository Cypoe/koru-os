#!/usr/bin/env bash
# Build the oracle walker and run it over mke2fs -d images in several geometries.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); W=${W:-/tmp/koruext2-host}; rm -rf "$W"; mkdir -p "$W/src/sub/deeper" "$W/src/many"
export PATH=/workspace/tc/zig-x86_64-linux-0.15.2:/usr/sbin:$PATH
cd "$W"
zig build-exe --dep ext2core -Mroot="$HERE/walk.zig" -Mext2core="$HERE/../ext2core.zig" -O Debug -femit-bin=walk
python3 - <<'P'
import os
r='src'
open(f'{r}/small.txt','w').write('hello koru\n')
open(f'{r}/empty','w').close()
open(f'{r}/sub/indirect.bin','wb').write(bytes((i*7+i//1024)%251 for i in range(300_000)))      # > 12 KiB + single indirect at 1 KiB
open(f'{r}/sub/deeper/double.bin','wb').write(bytes((i*13+i//4096)%253 for i in range(5_000_000)))  # double indirect at 1 KiB
with open(f'{r}/sparse.bin','wb') as f:
    f.seek(3_000_000); f.write(b'tail-after-hole'); f.seek(40_000); f.write(b'middle')
for i in range(300): open(f'{r}/many/entry-{i:04d}-with-a-longer-name','w').write(str(i))
os.symlink('small.txt', f'{r}/fastlink')
os.symlink('sub/deeper/' + 'x'*80 + '/../double.bin', f'{r}/slowlink')
P
pass=0; total=0
for spec in "1024 8192 none" "1024 8192 filetype" "1024 40960 filetype,sparse_super" "2048 20480 filetype,sparse_super,large_file" "4096 4096 filetype,sparse_super,large_file" "4096 12000 none"; do
  set -- $spec; total=$((total+1))
  img="img-$1-$2-${3//,/_}.img"; rm -f "$img"
  mke2fs -q -F -t ext2 -b "$1" -I 128 -N 2048 -O "$3" -d src "$img" "$2" >/dev/null
  e2fsck -fn "$img" >/dev/null 2>&1
  if ./walk "$img" src > "$img.walk.txt" 2>&1 && tail -1 "$img.walk.txt" | grep -q "WALK PASS"; then
    pass=$((pass+1)); echo "PASS $spec: $(head -1 "$img.walk.txt") $(tail -1 "$img.walk.txt")"
  else echo "FAIL $spec"; tail -3 "$img.walk.txt"; fi
done
# Refusal: ext4 extents must be refused at probe, image untouched.
mke2fs -q -F -t ext4 -d src ext4.img 16384 >/dev/null; h0=$(sha256sum ext4.img)
if ./walk ext4.img src > ext4.walk.txt 2>&1; then echo "FAIL ext4 accepted"; else echo "PASS ext4 refused: $(head -1 ext4.walk.txt)"; pass=$((pass+1)); fi; total=$((total+1))
[ "$h0" = "$(sha256sum ext4.img)" ] && echo "ext4 image unchanged"
echo "HOST TESTS $pass/$total"
