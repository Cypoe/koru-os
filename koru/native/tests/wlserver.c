// wlserver.elf — a minimal wl compositor endpoint speaking real wire
// bytes over a REAL pathname endpoint: socket()+bind("wayland-1") mints
// the S_IFSOCK node in the shared fs view, listen() opens the backlog,
// accept() pops the client's queued session end. stdout is fd1.
// Serves: registry globals, shm formats, surface/shm_pool/buffer
// objects, one attach+damage+frame+commit cycle answered by
// callback.done + buffer.release, and a display sync. The shm pool fd
// arrives over SCM_RIGHTS and is mmap'd MAP_SHARED — the pixels it
// reads are the client's writes to the same frame set. The node is
// left on disk: it's the gate's fs-visibility evidence (a real
// compositor would unlink it on shutdown).
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>
#include "wlwire.h"

#define WL_SOCK_NAME "wayland-1"

// koru scene seam: 515 mints a *Surf as an fd-table projection, 516
// blits a rect of client pixels into the provider backing (stride in
// bytes; rect rides memory like iovec), 517 commits damage through
// the z-stack. close(fd) detaches — compositor lifetime, not a verb.
#define K_SURF_OPEN    515
#define K_SURF_BLIT    516
#define K_SURF_PRESENT 517

int main(void) {
    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (lfd < 0) { printf("WLSRV FAIL socket e=%d\n", lfd); return 1; }
    struct sockaddr_un sa; memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    strcpy(sa.sun_path, WL_SOCK_NAME);
    unlink(WL_SOCK_NAME); // re-bind over a stale node — real servers do this
    if (bind(lfd, (struct sockaddr *)&sa, sizeof(sa.sun_family) + strlen(WL_SOCK_NAME) + 1) < 0) {
        printf("WLSRV FAIL bind\n"); return 1;
    }
    if (listen(lfd, 4) < 0) { printf("WLSRV FAIL listen\n"); return 1; }
    printf("WLSRV bound %s\n", WL_SOCK_NAME);
    int cfd = accept(lfd, 0, 0);
    if (cfd < 0) { printf("WLSRV FAIL accept\n"); return 1; }
    printf("WLSRV accepted fd=%d\n", cfd);

    struct wlconn cn; memset(&cn, 0, sizeof cn);
    cn.fd = cfd;
    unsigned char msg[1024], out[1024];
    struct wlw w;
    uint32_t reg = 0, comp = 0, shm = 0, surf = 0, pool = 0, buf = 0, cb = 0;
    uint32_t bufoff = 0, bufw = 0, bufh = 0, bufstride = 0;
    int poolfd = -1, poolsize = 0, surffd = -1;
    unsigned char *map = 0;

    for (;;) {
        int n = wl_next(&cn, msg, sizeof msg);
        if (n == 0) {
            printf("WLSRV EOS\n");
            // a dead client's last frame lingers — the compositor's
            // policy is to hold the scene a beat before teardown, the
            // same linger a real one shows while reaping. poll's tick
            // deadline carries the hold without starving the machine.
            if (surffd >= 0) {
                poll(0, 0, 1500);
                close(surffd); // detach — comp repaints the vacated rect
                printf("WLSRV surf released\n");
            }
            break;
        }
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
            bufoff = wl_arg(msg, 1); bufw = wl_arg(msg, 2);
            bufh = wl_arg(msg, 3); bufstride = wl_arg(msg, 4);
        } else if (oid == surf && op == 1) {  // surface.attach(buffer, x, y)
        } else if (oid == surf && op == 2) {  // surface.damage(x, y, w, h)
        } else if (oid == surf && op == 3) {  // surface.frame(new callback)
            cb = wl_arg(msg, 0);
        } else if (oid == surf && op == 6) {  // surface.commit — the frame lands
            uint32_t magic = wl_u32(map + 0), tag = wl_u32(map + 4);
            unsigned px0 = map[256];
            printf("WLSRV magic=%08x tag=%08x px0=%02x\n", magic, tag, px0);
            // commit IS the scene door: mint a *Surf sized to the
            // buffer on first frame, blit the client's shm bytes into
            // the provider backing, present full-surface damage. A
            // headless boot (no fb backend) refuses the mint and the
            // wire session still completes — weston's headless mode
            // is the same shape.
            if (bufw && bufh && map) {
                if (surffd < 0) {
                    surffd = (int)syscall(K_SURF_OPEN, bufw, bufh);
                    if (surffd < 0) {
                        printf("WLSRV surf refused e=%d\n", errno);
                        surffd = -1;
                    }
                }
                if (surffd >= 0) {
                    uint32_t rect[4] = { 0, 0, bufw, bufh };
                    long br = syscall(K_SURF_BLIT, surffd, map + bufoff,
                                      bufstride, rect);
                    int be = errno;
                    long pr = br < 0 ? br
                        : syscall(K_SURF_PRESENT, surffd, 0, 0, bufw, bufh);
                    int pe = errno;
                    printf("WLSRV surf %ux%u blit=%ld/%d present=%ld/%d\n",
                           bufw, bufh, br, be, pr, pe);
                }
            }
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
