#!/usr/bin/env bash
cd /workspace/koru-os-repo/experiments
K=/workspace/m7bclean/.unikraft/build/m7-input_qemu-x86_64; BB=/workspace/m3/busybox-1.37.0/busybox
M2K=/workspace/m2img/koruos/ext2/tests/.unikraft/build/koru_qemu-x86_64; R=/workspace/m7breg; A=/workspace/m7bacc
UDZ=/workspace/m7bin/src/libudev-zero/libudev.so.1
rm -rf $R $A; mkdir -p $R $A
for i in 1 2 3; do echo "m7b-$i $(date +%H:%M:%S)"; m7b-libinput/run-m7b.sh $K $BB /workspace/m7bin/root $UDZ $A/run-$i > /dev/null 2>&1; echo "m7b-$i $(tail -1 $A/run-$i/result.txt)"; done
echo "regress start $(date +%H:%M:%S)"
for i in 1 2 3; do
m3-ext2root/run-acceptance.sh $M2K $K $BB $R/m3-$i > $R/m3-$i.txt 2>&1; echo "m3-$i $(tail -1 $R/m3-$i.txt)"
m4-cyb/run-m4.sh $K $BB /workspace/m4build $R/m4-$i > $R/m4-$i.txt 2>&1; echo "m4-$i $(tail -1 $R/m4-$i.txt)"
m5-dyn/run-m5.sh $K /workspace/m5in $R/m5-$i > $R/m5-$i.txt 2>&1; echo "m5-$i $(tail -1 $R/m5-$i.txt)"
m6-kms/run-m6.sh $K $BB /workspace/m6in/root $R/m6-$i > $R/m6-$i.txt 2>&1; echo "m6-$i $(tail -1 $R/m6-$i.txt)"
m7-input/run-m7.sh $K $BB /workspace/m7in/root $R/m7-$i > $R/m7-$i.txt 2>&1; echo "m7-$i $(tail -1 $R/m7-$i.txt)"
m8-gl/run-m8.sh $K $BB /workspace/m8in/root $R/m8a-$i > $R/m8a-$i.txt 2>&1; echo "m8a-$i $(tail -1 $R/m8a-$i.txt)"
SLP=25 m8-gl/run-m8b.sh $K $BB /workspace/m8in/root /workspace/m8in/kroot $R/m8b-$i 150 > $R/m8b-$i.txt 2>&1; echo "m8b-$i $(tail -1 $R/m8b-$i/result.txt)"
done; echo "end $(date +%H:%M:%S)"
