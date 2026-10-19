#!/usr/bin/env bash
cd /workspace/koru-os-repo/experiments
K=/workspace/m7kclean/.unikraft/build/m7-input_qemu-x86_64; BB=/workspace/m3/busybox-1.37.0/busybox
M2K=/workspace/m2img/koruos/ext2/tests/.unikraft/build/koru_qemu-x86_64; R=/workspace/m7reg
rm -rf $R; mkdir -p $R; date +start-%H:%M:%S
for i in 1 2 3; do
m3-ext2root/run-acceptance.sh $M2K $K $BB $R/m3-$i > $R/m3-$i.txt 2>&1; echo "m3-$i $(tail -1 $R/m3-$i.txt)"
m4-cyb/run-m4.sh $K $BB /workspace/m4build $R/m4-$i > $R/m4-$i.txt 2>&1; echo "m4-$i $(tail -1 $R/m4-$i.txt)"
m5-dyn/run-m5.sh $K /workspace/m5in $R/m5-$i > $R/m5-$i.txt 2>&1; echo "m5-$i $(tail -1 $R/m5-$i.txt)"
m6-kms/run-m6.sh $K $BB /workspace/m6in/root $R/m6-$i > $R/m6-$i.txt 2>&1; echo "m6-$i $(tail -1 $R/m6-$i.txt)"
done; date +end-%H:%M:%S
