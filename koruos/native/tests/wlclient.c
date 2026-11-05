// wlclient.elf — a minimal wl client speaking real wire bytes over a
// REAL pathname endpoint: socket()+connect("wayland-1") — the connect
// resolves the S_IFSOCK node in the shared fs view and queues a session
// on the server's backlog. Connect retries are the unix idiom: the
// server races us to bind+listen, ENOENT/ECONNREFUSED until it's up.
// stdout is fd1. Plays the canonical session: get_registry → bind
// compositor+shm → create a surface, back it with a memfd shm pool
// (the fd crosses SCM_RIGHTS), write pixels through its own
// MAP_SHARED mapping, attach+commit, wait the frame callback, then sync.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>
#include "wlwire.h"

static int memfd_create(const char *name, unsigned flags) {
    return (int)syscall(319, name, flags);
}

int main(void) {
    int sfd = -1;
    struct sockaddr_un sa; memset(&sa, 0, sizeof sa);
    sa.sun_family = AF_UNIX;
    strcpy(sa.sun_path, "wayland-1");
    int tries = 0;
    for (;;) {
        sfd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (sfd < 0) { printf("WLCLI FAIL socket\n"); return 1; }
        int cr = connect(sfd, (struct sockaddr *)&sa,
                    sizeof(sa.sun_family) + strlen("wayland-1") + 1);
        if (cr == 0) break;
        if (tries < 5 || tries % 20000 == 0)
            printf("WLCLI try%d cr=%d\n", tries, cr);
        close(sfd);
        sfd = -1;
        if (++tries > 100000) { printf("WLCLI FAIL connect\n"); return 1; }
    }
    printf("WLCLI connected tries=%d\n", tries);

    struct wlconn cn; memset(&cn, 0, sizeof cn);
    cn.fd = sfd;
    unsigned char msg[1024], out[1024];
    struct wlw w;

    // display.get_registry(new_id=2)
    wlw_init(&w, out, 1, 1); wlw_u32(&w, 2);
    if (wl_send(cn.fd, out, wlw_len(&w)) < 0) { printf("WLCLI FAIL send\n"); return 1; }

    // registry.global x2 — collect names
    int nglob = 0;
    while (nglob < 2) {
        int n = wl_next(&cn, msg, sizeof msg);
        if (n <= 0) { printf("WLCLI FAIL reg\n"); return 1; }
        if (wl_u16(msg + 4) != 0) { printf("WLCLI ?ev %u\n", wl_u16(msg + 4)); continue; }
        int nx; const char *ifn = wl_sarg(msg, 12, &nx);
        printf("WLCLI global %u %s v%u\n", wl_arg(msg, 0), ifn, wl_u32(msg + nx));
        nglob++;
    }

    // bind wl_compositor (global 1) → id 3, wl_shm (global 2) → id 4
    wlw_init(&w, out, 2, 0);
    wlw_u32(&w, 1); wlw_str(&w, "wl_compositor"); wlw_u32(&w, 4); wlw_u32(&w, 3);
    wl_send(cn.fd, out, wlw_len(&w));
    wlw_init(&w, out, 2, 0);
    wlw_u32(&w, 2); wlw_str(&w, "wl_shm"); wlw_u32(&w, 1); wlw_u32(&w, 4);
    wl_send(cn.fd, out, wlw_len(&w));

    // expect shm.format x2 on object 4
    int nfmt = 0;
    while (nfmt < 2) {
        int n = wl_next(&cn, msg, sizeof msg);
        if (n <= 0) { printf("WLCLI FAIL fmt\n"); return 1; }
        if (wl_u32(msg) == 4 && wl_u16(msg + 4) == 0) nfmt++;
    }

    // compositor.create_surface(new_id=5)
    wlw_init(&w, out, 3, 0); wlw_u32(&w, 5);
    wl_send(cn.fd, out, wlw_len(&w));

    // the shm pool: a memfd we size, map shared, and paint before the fd
    // ever crosses — the server reads the same frame set. Size must
    // cover the buffer it backs (64*64*4) — a short pool is a hole.
    const int poolsize = 64 * 64 * 4;
    int mfd = memfd_create("wlpool", 0);
    if (mfd < 0) { printf("WLCLI FAIL memfd e=%d\n", mfd); return 1; }
    if (ftruncate(mfd, poolsize) < 0) { printf("WLCLI FAIL trunc\n"); return 1; }
    unsigned char *map = mmap(0, poolsize, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, 0);
    if (map == MAP_FAILED) { printf("WLCLI FAIL mmap\n"); return 1; }
    wl_le32(map + 0, 0xdeadbeef);
    wl_le32(map + 4, 0x00c0ffee);
    map[256] = 0x5a;

    // shm.create_pool(new_id=6, fd=mfd, size=poolsize) — fd rides ancillary
    wlw_init(&w, out, 4, 0); wlw_u32(&w, 6); wlw_i32(&w, poolsize);
    if (wl_sendfd(cn.fd, out, wlw_len(&w), mfd) < 0) { printf("WLCLI FAIL pool\n"); return 1; }

    // pool.create_buffer(new_id=7, offset=0, 64x64, stride=256, fmt=argb8888)
    wlw_init(&w, out, 6, 0);
    wlw_u32(&w, 7); wlw_i32(&w, 0); wlw_i32(&w, 64); wlw_i32(&w, 64);
    wlw_i32(&w, 256); wlw_u32(&w, 0);
    wl_send(cn.fd, out, wlw_len(&w));

    // surface.attach(buffer=7) + damage + frame(cb=8) + commit
    wlw_init(&w, out, 5, 1); wlw_u32(&w, 7); wlw_i32(&w, 0); wlw_i32(&w, 0);
    wl_send(cn.fd, out, wlw_len(&w));
    wlw_init(&w, out, 5, 2);
    wlw_i32(&w, 0); wlw_i32(&w, 0); wlw_i32(&w, 64); wlw_i32(&w, 64);
    wl_send(cn.fd, out, wlw_len(&w));
    wlw_init(&w, out, 5, 3); wlw_u32(&w, 8);
    wl_send(cn.fd, out, wlw_len(&w));
    wlw_init(&w, out, 5, 6);
    wl_send(cn.fd, out, wlw_len(&w));

    // display.sync(new callback=9)
    wlw_init(&w, out, 1, 0); wlw_u32(&w, 9);
    wl_send(cn.fd, out, wlw_len(&w));

    // read events until the sync callback's done lands
    int framedone = 0, released = 0;
    for (;;) {
        int n = wl_next(&cn, msg, sizeof msg);
        if (n <= 0) { printf("WLCLI FAIL ev\n"); return 1; }
        uint32_t oid = wl_u32(msg); uint16_t op = wl_u16(msg + 4);
        if (oid == 8 && op == 0) {
            framedone = 1;
            printf("WLCLI frame done=%u\n", wl_arg(msg, 0));
        } else if (oid == 7 && op == 0) {
            released = 1;
            printf("WLCLI buffer release\n");
        } else if (oid == 9 && op == 0) {
            printf("WLCLI sync done=%u framed=%d rel=%d\n",
                   wl_arg(msg, 0), framedone, released);
            break;
        } else if (oid == 1 && op == 1) {
            // display.delete_id — expected, quiet
        } else {
            printf("WLCLI ?ev oid=%u op=%u\n", oid, op);
        }
    }
    printf("WLCLI COMPLETE\n");
    return 0;
}
