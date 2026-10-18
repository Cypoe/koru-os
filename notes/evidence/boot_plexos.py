#!/usr/bin/env python3
# koru study harness: headless TCG boot of plex-os, drive REPL over COM1, capture serial.
import subprocess, threading, time, sys
K=sys.argv[1]; OUT=sys.argv[2]
cmd=["qemu-system-i386","-kernel",K,"-m","256M","-display","none","-serial","stdio","-no-reboot","-monitor","none"]
p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
buf=[];t0=time.time();marks=[]
def rd():
    while True:
        c=p.stdout.read1(4096)
        if not c: break
        buf.append((time.time()-t0,c))
threading.Thread(target=rd,daemon=True).start()
def wait_for(s,tmo):
    end=time.time()+tmo
    while time.time()<end:
        if s in b"".join(c for _,c in buf): return True
        time.sleep(0.05)
    return False
ok=wait_for(b"plex-os> ",30); marks.append(("first prompt", ok, round(time.time()-t0,2)))
for c in [b"help",b"cpu",b"mem",b"mmap",b"exo",b"carriers",b"eval (K I) S",b"(B W) (K I)",b"eval S K K x",b"doom",b"bogus"]:
    p.stdin.write(c+b"\r"); p.stdin.flush(); time.sleep(1.0)
time.sleep(1); p.kill()
open(OUT,"wb").write(b"".join(c for _,c in buf))
print(cmd); print(marks)
