// wlserver.elf — a minimal wl compositor endpoint speaking real wire
// bytes. spawn_start wires the socketpair end in as fd0; stdout is fd1.
// Serves: registry globals, shm formats, surface/shm_pool/buffer
// objects, one attach+damage+frame+commit cycle answered by
// callback.done + buffer.release, and a display sync. The shm pool fd
// arrives over SCM_RIGHTS and is mmap'd MAP_SHARED — the pixels it
// reads are the client's writes to the same frame set.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "wlwire.h"

int main(void) {
    struct wlconn cn; memset(&cn, 0, sizeof cn);
    cn.fd = 0; // socket end rides in as fd0
    unsigned char msg[1024], out[1024];
    struct wlw w;
    uint32_t reg = 0, comp = 0, shm = 0, surf = 0, pool = 0, buf = 0, cb = 0;
    int poolfd = -1, poolsize = 0;
    unsigned char *map = 0;

    for (;;) {
        int n = wl_next(&cn, msg, sizeof msg);
        if (n == 0) { printf("WLSRV EOS\n"); break; }
        if (n < 0) { printf("WLSRV FAIL wire\n"); return 1; }
        uint32_t oid = wl_u32(msg);
        uint16_t op = wl_u16(msg + 4);

        if (oid == 1 && op == 1) {            // display.get_registry(new_id)
            reg = wl_arg(msg, 0);
            wlw_init(&w, out, reg, 0);        // registry.global
            wlw_u32(&w, 1); wlw_str(&w, "wl_compositor"); wlw_u32(&w, 4);
            wl_send(cn.fd, out, wlw_len(&w));
            wlw_init(&w, out, reg, 0);
            wlw_u32(&w, 2); wlw_str(&w, "wl_shm"); wlw_u32(&w, 1);
            wl_send(cn.fd, out, wlw_len(&w));
        } else if (oid == reg && op == 0) {   // registry.bind(name, iface, ver, id)
            uint32_t name = wl_arg(msg, 0);
            int nx; const char *ifn = wl_sarg(msg, 12, &nx);
            uint32_t newid = wl_u32(msg + nx + 4); // +4 skips version
            if (!strcmp(ifn, "wl_shm")) {
                shm = newid;
                wlw_init(&w, out, shm, 0); wlw_u32(&w, 0); // format argb8888
                wl_send(cn.fd, out, wlw_len(&w));
                wlw_init(&w, out, shm, 0); wlw_u32(&w, 1); // xrgb8888
                wl_send(cn.fd, out, wlw_len(&w));
            } else if (!strcmp(ifn, "wl_compositor")) {
                comp = newid;
            } else {
                printf("WLSRV ?bind %s\n", ifn);
            }
        } else if (oid == comp && op == 0) {  // compositor.create_surface(new_id)
            surf = wl_arg(msg, 0);
        } else if (oid == shm && op == 0) {   // shm.create_pool(new_id, fd, size)
            pool = wl_arg(msg, 0);
            poolsize = (int)wl_arg(msg, 1);
            poolfd = wl_popfd(&cn);           // the SCM_RIGHTS payload
            if (poolfd < 0) { printf("WLSRV FAIL nofd\n"); return 1; }
            map = mmap(0, poolsize, PROT_READ | PROT_WRITE, MAP_SHARED, poolfd, 0);
            if (map == MAP_FAILED) { printf("WLSRV FAIL mmap\n"); return 1; }
        } else if (oid == pool && op == 0) {  // pool.create_buffer(new_id, off, w, h, stride, fmt)
            buf = wl_arg(msg, 0);
        } else if (oid == surf && op == 1) {  // surface.attach(buffer, x, y)
        } else if (oid == surf && op == 2) {  // surface.damage(x, y, w, h)
        } else if (oid == surf && op == 3) {  // surface.frame(new callback)
            cb = wl_arg(msg, 0);
        } else if (oid == surf && op == 6) {  // surface.commit — the frame lands
            uint32_t magic = wl_u32(map + 0), tag = wl_u32(map + 4);
            unsigned px0 = map[256];
            printf("WLSRV magic=%08x tag=%08x px0=%02x\n", magic, tag, px0);
            wlw_init(&w, out, cb, 0); wlw_u32(&w, 42);     // callback.done
            wl_send(cn.fd, out, wlw_len(&w));
            wlw_init(&w, out, buf, 0);                     // buffer.release
            wl_send(cn.fd, out, wlw_len(&w));
        } else if (oid == 1 && op == 0) {     // display.sync(new callback)
            uint32_t scb = wl_arg(msg, 0);
            wlw_init(&w, out, scb, 0); wlw_u32(&w, 43);
            wl_send(cn.fd, out, wlw_len(&w));
            wlw_init(&w, out, 1, 1); wlw_u32(&w, scb);     // display.delete_id
            wl_send(cn.fd, out, wlw_len(&w));
        } else {
            printf("WLSRV ?msg oid=%u op=%u\n", oid, op);
        }
    }
    return 0;
}
