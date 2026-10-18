#!/usr/bin/env python3
# koru study harness: boot plex-os with DOOM as multiboot modules, type `doom`, capture serial + screendumps.
import subprocess, threading, time, sys, socket, os
K,DOOM,WAD,OUT=sys.argv[1:5]
mon="/tmp/plexmon.sock"
if os.path.exists(mon): os.remove(mon)
cmd=["qemu-system-i386","-kernel",K,"-initrd",f"{DOOM},{WAD}","-m","512M","-vga","std",
     "-display","none","-serial","stdio","-no-reboot","-monitor",f"unix:{mon},server,nowait"]
p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
buf=[];t0=time.time()
def rd():
    while True:
        c=p.stdout.read1(4096)
        if not c: break
        buf.append(c)
threading.Thread(target=rd,daemon=True).start()
def have(s): return s in b"".join(buf)
def mcmd(c):
    s=socket.socket(socket.AF_UNIX); s.connect(mon); time.sleep(0.2); s.recv(4096)
    s.sendall(c.encode()+b"\n"); time.sleep(0.8); s.close()
end=time.time()+30
while not have(b"plex-os> ") and time.time()<end: time.sleep(0.1)
print("prompt at",round(time.time()-t0,2))
p.stdin.write(b"doom\r"); p.stdin.flush(); td=time.time()
for i,w in enumerate([20]):
    time.sleep(w); mcmd(f"screendump {OUT}.shot{i}.ppm"); print("shot",i,"at +",round(time.time()-td,1),"s after doom")
[ (mcmd("sendkey ret"), time.sleep(1.5)) for _ in range(4) ]; time.sleep(6); mcmd(f"screendump {OUT}.shot4.ppm"); [ (mcmd("sendkey up"),) for _ in range(15) ]; time.sleep(3)
mcmd(f"screendump {OUT}.shot3.ppm")
p.kill(); open(OUT,"wb").write(b"".join(buf)); print(cmd)
