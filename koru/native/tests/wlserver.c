// wlserver.elf — a real wl compositor endpoint, multi-client edition:
// socket()+bind("wayland-1") mints the S_IFSOCK node, listen() opens
// the backlog, accept() pops queued session ends — then a poll loop
// multiplexes {listener, input fd, every client conn}. stdout is fd1.
//
// Serves: registry globals (wl_compositor v4, wl_shm v1, wl_seat v7),
// shm formats, surface/shm_pool/buffer objects, attach+damage+frame+
// commit answered by callback.done + buffer.release, display sync,
// and a SEAT: capabilities on bind, wl_pointer enter/leave/motion/
// button/frame routed by the compositor's own hit-test over the scene
// surface list, wl_keyboard keymap + key to the pointer-focused
// client. The shm pool fd arrives over SCM_RIGHTS and is mmap'd
// MAP_SHARED; commit mints a real *Surf through the scene seam, blits
// the client's shm bytes, presents damage through the z-stack.
//
// Input is the compositor's second capability: nr518 mints an
// evdev-shaped fd over the machine's merged input rings — this child
// reads InEv records a client never sees, tracks the pointer position
// itself (the kernel cursor already follows the same deltas), and
// turns hits into protocol. Button-held motion drags the focused
// surface through nr519 — placement is compositor policy, exercised
// for real. The node is left on disk: fs-visibility evidence.
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include "wlwire.h"

#define WL_SOCK_NAME "wayland-1"

// koru scene seam: 515 mints a *Surf as an fd-table projection, 516
// blits a rect of client pixels into the provider backing (stride in
// bytes; rect rides memory like iovec), 517 commits damage through
// the z-stack, 518 mints the input reader, 519 moves a surface (the
// provider damages old+new), 520 reads back rect+scene extent.
// close(surffd) detaches — compositor lifetime, not a verb.
#define K_SURF_OPEN    515
#define K_SURF_BLIT    516
#define K_SURF_PRESENT 517
#define K_INPUT_OPEN   518
#define K_SURF_MOVE    519
#define K_SURF_INFO    520

#define NCLI 4   // live sessions, accepted via the listen backlog
#define NSURF 8  // scene surfaces across all clients

// one provider event record — identical layout to kbd.InEv: kind 1 =
// key (evdev code, set-1 numerology), 2 = button (X code 1L/2M/3R),
// 3 = motion (raw deltas). The wire never sees the ring.
struct inev { uint32_t kind, code, pressed; int32_t dx, dy; };

struct scene_geom { uint32_t x, y, w, h, sw, sh; };

// a placed scene surface — minted on its wl_surface's first commit
struct scsurf {
    int live;
    int cli;          // owning session
    uint32_t wloid;   // the client's wl_surface id
    int fd;           // the *Surf projection
    uint32_t x, y, w, h;
};

// a client's surface slot: wire objects + the pool it commits from
struct csurf {
    uint32_t surf, buf, pool, cb;
    int poolfd, poolsize, surfix;   // surfix: index into scs[], -1 none
    unsigned char *map;
    uint32_t boff, bw, bh, bstride;
};

struct cl {
    struct wlconn cn;
    int dead;
    uint32_t reg, comp, shm, seat, ptr, kbd;
    struct csurf S;
};

static struct cl cls[NCLI];
static struct scsurf scs[NSURF];
static struct inev evs[16];
static unsigned char msg[1024], out[1024];
static uint32_t serial = 1;
static uint32_t px, py;            // compositor-tracked pointer pos
static uint32_t sw, sh;            // scene extent (learned lazily)
static int focus = -1;             // scs[] index under the pointer
static int drag = -1;              // scs[] index being drag-moved

static uint32_t msec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static void wsend(struct cl *c, struct wlw *w) {
    wl_send(c->cn.fd, out, wlw_len(w));
}

static void ptr_leave(struct cl *c, struct scsurf *s) {
    if (!c->ptr) return;
    struct wlw w;
    wlw_init(&w, out, c->ptr, 1);      // leave(serial, surface)
    wlw_u32(&w, serial++); wlw_u32(&w, s->wloid);
    wsend(c, &w);
}
static void ptr_enter(struct cl *c, struct scsurf *s) {
    if (!c->ptr) return;
    struct wlw w;
    wlw_init(&w, out, c->ptr, 0);      // enter(serial, surface, sx, sy)
    wlw_u32(&w, serial++); wlw_u32(&w, s->wloid);
    wlw_i32(&w, (int32_t)(px - s->x) << 8);
    wlw_i32(&w, (int32_t)(py - s->y) << 8);
    wsend(c, &w);
}
static void ptr_frame(struct cl *c) {
    if (!c->ptr) return;
    struct wlw w;
    wlw_init(&w, out, c->ptr, 5);      // frame()
    wsend(c, &w);
}
static void kbd_enter(struct cl *c, struct scsurf *s) {
    if (!c->kbd) return;
    struct wlw w;
    wlw_init(&w, out, c->kbd, 1);      // enter(serial, surface, keys[])
    wlw_u32(&w, serial++); wlw_u32(&w, s->wloid); wlw_u32(&w, 0);
    wsend(c, &w);
}
static void kbd_leave(struct cl *c, struct scsurf *s) {
    if (!c->kbd) return;
    struct wlw w;
    wlw_init(&w, out, c->kbd, 2);      // leave(serial, surface)
    wlw_u32(&w, serial++); wlw_u32(&w, s->wloid);
    wsend(c, &w);
}

// topmost surface under (px,py) — scs[] order IS z order (attach
// appends), so scan high slots first.
static int hit(void) {
    for (int i = NSURF - 1; i >= 0; i--) {
        struct scsurf *s = &scs[i];
        if (s->live && px >= s->x && px < s->x + s->w &&
            py >= s->y && py < s->y + s->h) return i;
    }
    return -1;
}

static void refocus(void) {
    int n = hit();
    if (n == focus) return;
    if (focus >= 0) {
        struct scsurf *o = &scs[focus];
        ptr_leave(&cls[o->cli], o);
        kbd_leave(&cls[o->cli], o);
    }
    focus = n;
    if (focus >= 0) {
        struct scsurf *s = &scs[focus];
        ptr_enter(&cls[s->cli], s);
        kbd_enter(&cls[s->cli], s);
    }
}

static void on_input(int ifd) {
    long n = read(ifd, evs, sizeof evs);
    if (n < (long)sizeof evs[0]) return;
    for (int i = 0; i < n / (long)sizeof evs[0]; i++) {
        struct inev *e = &evs[i];
        printf("WLSRV ev k=%u c=%u p=%u dx=%d dy=%d\n",
               e->kind, e->code, e->pressed, e->dx, e->dy);
        if (e->kind == 3) {                    // motion
            int nx = (int)px + e->dx, ny = (int)py + e->dy;
            if (nx < 0) nx = 0; if (ny < 0) ny = 0;
            if (sw && nx >= (int)sw) nx = (int)sw - 1;
            if (sh && ny >= (int)sh) ny = (int)sh - 1;
            px = (uint32_t)nx; py = (uint32_t)ny;
            // drag wins over focus: a held button moves the grabbed
            // surface — placement is the compositor's call, not the
            // client's. The scene is re-hit-tested on release.
            if (drag >= 0) {
                struct scsurf *s = &scs[drag];
                if (s->live) {
                    int mx = (int)s->x + e->dx, my = (int)s->y + e->dy;
                    if (mx < 0) mx = 0; if (my < 0) my = 0;
                    syscall(K_SURF_MOVE, s->fd, (uint32_t)mx, (uint32_t)my);
                    s->x = (uint32_t)mx; s->y = (uint32_t)my;
                    printf("WLSRV move %u,%u\n", s->x, s->y);
                }
            } else {
                refocus();
            }
            if (focus >= 0) {
                struct scsurf *s = &scs[focus];
                struct cl *c = &cls[s->cli];
                if (c->ptr) {
                    struct wlw w;
                    wlw_init(&w, out, c->ptr, 2);  // motion(time, sx, sy)
                    wlw_u32(&w, msec());
                    wlw_i32(&w, (int32_t)(px - s->x) << 8);
                    wlw_i32(&w, (int32_t)(py - s->y) << 8);
                    wsend(c, &w);
                    ptr_frame(c);
                }
            }
        } else if (e->kind == 2) {             // button
            // X code 1L/2M/3R -> evdev BTN_LEFT/MIDDLE/RIGHT
            uint32_t btn = e->code == 1 ? 0x110 :
                           e->code == 3 ? 0x111 : 0x112;
            if (e->pressed && focus >= 0) drag = focus;
            if (!e->pressed) { drag = -1; refocus(); } // grab ends — re-hit
            if (focus >= 0) {
                struct cl *c = &cls[scs[focus].cli];
                if (c->ptr) {
                    struct wlw w;
                    wlw_init(&w, out, c->ptr, 3);  // button(ser, t, btn, st)
                    wlw_u32(&w, serial++); wlw_u32(&w, msec());
                    wlw_u32(&w, btn); wlw_u32(&w, e->pressed);
                    wsend(c, &w);
                    ptr_frame(c);
                }
            }
        } else if (e->kind == 1) {             // key
            if (focus >= 0) {
                struct cl *c = &cls[scs[focus].cli];
                if (c->kbd) {
                    struct wlw w;
                    wlw_init(&w, out, c->kbd, 3);  // key(ser, t, key, st)
                    wlw_u32(&w, serial++); wlw_u32(&w, msec());
                    wlw_u32(&w, e->code);          // set-1 == evdev on
                    wlw_u32(&w, e->pressed);       // the common range
                    wsend(c, &w);
                }
            }
        }
    }
}

// minimal XKB keymap text — a real keymap fd is protocol-required
// before key events; a tiny valid-shaped map rides a memfd (parsing
// is the client's xkbcommon, not our contract).
static const char KEYMAP[] =
    "xkb_keymap {\n"
    "  xkb_keycodes \"evdev\" { minimum = 8; maximum = 255; };\n"
    "  xkb_types \"default\" { };\n"
    "  xkb_compat \"default\" { };\n"
    "  xkb_symbols \"default\" { };\n"
    "};\n";

static void kbd_keymap(struct cl *c) {
    int mfd = (int)syscall(319, "xkb", 0);   // memfd_create
    if (mfd < 0) return;
    int sz = (int)sizeof(KEYMAP) - 1;
    write(mfd, KEYMAP, sz);
    struct wlw w;
    wlw_init(&w, out, c->kbd, 0);            // keymap(format, fd, size)
    wlw_u32(&w, 1);                          // WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1
    wlw_u32(&w, (uint32_t)sz);
    wl_sendfd(c->cn.fd, out, wlw_len(&w), mfd);
    close(mfd);
}

static void dispatch(struct cl *c) {
    uint32_t oid = wl_u32(msg);
    uint16_t op = wl_u16(msg + 4);
    struct csurf *S = &c->S;
    struct wlw w;

    if (oid == 1 && op == 1) {              // display.get_registry(new_id)
        c->reg = wl_arg(msg, 0);
        static const char *const gname[] = {
            "wl_compositor", "wl_shm", "wl_seat" };
        static const uint32_t gver[] = { 4, 1, 7 };
        for (uint32_t i = 0; i < 3; i++) {
            wlw_init(&w, out, c->reg, 0);    // registry.global
            wlw_u32(&w, i + 1); wlw_str(&w, gname[i]); wlw_u32(&w, gver[i]);
            wsend(c, &w);
        }
    } else if (oid == c->reg && op == 0) {  // registry.bind(name, iface, ver, id)
        uint32_t name = wl_arg(msg, 0);
        int nx; const char *ifn = wl_sarg(msg, 12, &nx);
        uint32_t newid = wl_u32(msg + nx + 4); // +4 skips version
        if (!strcmp(ifn, "wl_shm")) {
            c->shm = newid;
            wlw_init(&w, out, c->shm, 0); wlw_u32(&w, 0);
            wsend(c, &w);
            wlw_init(&w, out, c->shm, 0); wlw_u32(&w, 1);
            wsend(c, &w);
        } else if (!strcmp(ifn, "wl_compositor")) {
            c->comp = newid;
        } else if (!strcmp(ifn, "wl_seat")) {
            c->seat = newid;
            wlw_init(&w, out, c->seat, 0);   // seat.capabilities
            wlw_u32(&w, 3);                  // pointer | keyboard
            wsend(c, &w);
            printf("WLSRV seat caps\n");
        } else {
            printf("WLSRV ?bind %s\n", ifn);
        }
    } else if (oid == c->seat && op == 0) { // seat.get_pointer(new_id)
        c->ptr = wl_arg(msg, 0);
    } else if (oid == c->seat && op == 1) { // seat.get_keyboard(new_id)
        c->kbd = wl_arg(msg, 0);
        kbd_keymap(c);                       // keymap precedes keys
    } else if (oid == c->ptr && op == 0) {  // pointer.set_cursor — image
    } else if (oid == c->ptr && op == 1) {  // pointer.release
        c->ptr = 0;
    } else if (oid == c->comp && op == 0) { // compositor.create_surface
        S->surf = wl_arg(msg, 0);
    } else if (oid == c->shm && op == 0) {  // shm.create_pool(new, fd, size)
        S->pool = wl_arg(msg, 0);
        S->poolsize = (int)wl_arg(msg, 1);
        S->poolfd = wl_popfd(&c->cn);
        if (S->poolfd < 0) { printf("WLSRV FAIL nofd\n"); c->dead = 1; return; }
        S->map = mmap(0, S->poolsize, PROT_READ | PROT_WRITE,
                      MAP_SHARED, S->poolfd, 0);
        if (S->map == MAP_FAILED) { printf("WLSRV FAIL mmap\n"); c->dead = 1; return; }
    } else if (oid == S->pool && op == 0) { // pool.create_buffer(...)
        S->buf = wl_arg(msg, 0);
        S->boff = wl_arg(msg, 1); S->bw = wl_arg(msg, 2);
        S->bh = wl_arg(msg, 3); S->bstride = wl_arg(msg, 4);
    } else if (oid == S->pool && op == 1) { // pool.destroy
        S->pool = 0;
    } else if (oid == S->buf && op == 0) {  // buffer.destroy
        S->buf = 0;
    } else if (oid == S->surf && op == 0) { // surface.destroy
        S->surf = 0;
    } else if (oid == S->surf && op == 1) { // surface.attach(buf, x, y)
    } else if (oid == S->surf && op == 2) { // surface.damage(x, y, w, h)
    } else if (oid == S->surf && op == 3) { // surface.frame(new callback)
        S->cb = wl_arg(msg, 0);
    } else if (oid == S->surf && op == 6) { // surface.commit — frame lands
        if (S->bw && S->bh && S->map) {
            uint32_t magic = wl_u32(S->map + S->boff);
            uint32_t tag = wl_u32(S->map + S->boff + 4);
            unsigned px0 = S->boff + 256 < (uint32_t)S->poolsize
                         ? S->map[S->boff + 256] : 0;
            printf("WLSRV magic=%08x tag=%08x px0=%02x\n", magic, tag, px0);
            if (S->surfix < 0) {
                // commit IS the scene door: mint a *Surf at the next
                // tile slot; headless boot refuses the mint and the
                // wire session still completes.
                for (int i = 0; i < NSURF && S->surfix < 0; i++)
                    if (!scs[i].live) S->surfix = i;
                if (S->surfix >= 0) {
                    struct scsurf *t = &scs[S->surfix];
                    int f = (int)syscall(K_SURF_OPEN, S->bw, S->bh);
                    if (f >= 0) {
                        t->live = 1; t->cli = (int)(c - cls);
                        t->wloid = S->surf; t->fd = f;
                        t->w = S->bw; t->h = S->bh;
                        t->x = 40 + 100 * (uint32_t)S->surfix;
                        t->y = 40 + 100 * (uint32_t)S->surfix;
                        syscall(K_SURF_MOVE, t->fd, t->x, t->y);
                        struct scene_geom g;
                        if (syscall(K_SURF_INFO, t->fd, &g) == 0) {
                            sw = g.sw; sh = g.sh;
                            t->x = g.x; t->y = g.y;
                        }
                        printf("WLSRV surf slot=%d magic=%08x\n",
                               S->surfix, magic);
                    } else {
                        printf("WLSRV surf refused e=%d\n", errno);
                        S->surfix = -1;
                    }
                }
            }
            if (S->surfix >= 0) {
                uint32_t rect[4] = { 0, 0, S->bw, S->bh };
                long br = syscall(K_SURF_BLIT, scs[S->surfix].fd,
                                  S->map + S->boff, S->bstride, rect);
                int be = br < 0 ? errno : 0;
                long pr = br < 0 ? br
                    : syscall(K_SURF_PRESENT, scs[S->surfix].fd,
                              0, 0, S->bw, S->bh);
                int pe = pr < 0 ? errno : 0;
                printf("WLSRV surf %ux%u blit=%ld/%d present=%ld/%d\n",
                       S->bw, S->bh, br, be, pr, pe);
            }
        }
        if (S->cb) {
            wlw_init(&w, out, S->cb, 0); wlw_u32(&w, 42);
            wsend(c, &w);
            S->cb = 0;
        }
        if (S->buf) {
            wlw_init(&w, out, S->buf, 0);    // buffer.release
            wsend(c, &w);
        }
    } else if (oid == 1 && op == 0) {       // display.sync(new callback)
        uint32_t scb = wl_arg(msg, 0);
        wlw_init(&w, out, scb, 0); wlw_u32(&w, 43);
        wsend(c, &w);
        wlw_init(&w, out, 1, 1); wlw_u32(&w, scb);
        wsend(c, &w);
    } else {
        printf("WLSRV ?msg oid=%u op=%u\n", oid, op);
    }
}

static void teardown(struct cl *c) {
    if (c->S.surfix >= 0) {
        struct scsurf *s = &scs[c->S.surfix];
        if (s->live) {
            if (focus == (int)(s - scs)) { focus = -1; }
            if (drag == (int)(s - scs)) { drag = -1; }
            close(s->fd);           // detach — comp repaints the rect
            s->live = 0;
            printf("WLSRV surf released slot=%d\n", (int)(s - scs));
        }
        c->S.surfix = -1;
    }
    if (c->S.poolfd >= 0) close(c->S.poolfd);
    c->dead = 1;
    printf("WLSRV EOS\n");
}

int main(void) {
    // a compositor's log IS its evidence — unbuffered, or every line
    // lands posthumously at exit and an injector chasing serial sees
    // a world that ended seconds ago.
    setvbuf(stdout, 0, _IONBF, 0);
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

    // the compositor's second cap: an evdev-shaped reader over the
    // machine's input rings. Refused (no bag bit) means the session
    // still runs — input routing just has no source.
    int ifd = (int)syscall(K_INPUT_OPEN);
    int iopen = errno;
    printf("WLSRV input %s e=%d\n", ifd >= 0 ? "open" : "refused",
           ifd >= 0 ? 0 : iopen);
    px = py = 0;

    memset(cls, 0, sizeof cls);
    for (int i = 0; i < NCLI; i++) { cls[i].cn.fd = -1; cls[i].dead = 1; cls[i].S.surfix = -1; cls[i].S.poolfd = -1; }

    struct pollfd pf[2 + NCLI];
    int ever = 0;
    for (;;) {
        int nf = 0;
        pf[nf].fd = lfd; pf[nf].events = POLLIN; nf++;
        if (ifd >= 0) { pf[nf].fd = ifd; pf[nf].events = POLLIN; nf++; }
        int live = 0;
        for (int i = 0; i < NCLI; i++) {
            if (!cls[i].dead) {
                pf[nf].fd = cls[i].cn.fd; pf[nf].events = POLLIN; nf++;
                live++;
            }
        }
        // quiescence policy: once clients have come and ALL have gone,
        // a beat of silence ends the compositor — a real one idles
        // forever; the gate needs a reachable exit.
        int pr = poll(pf, nf, ever && live == 0 ? 1500 : -1);
        if (pr == 0) break;                    // quiet deadline — done
        if (pr < 0) { printf("WLSRV FAIL poll e=%d\n", errno); return 1; }
        int pos = 0;
        if (pf[pos].revents & POLLIN) {        // accept
            int cfd = accept(lfd, 0, 0);
            if (cfd >= 0) {
                for (int i = 0; i < NCLI; i++) {
                    if (cls[i].dead) {
                        memset(&cls[i], 0, sizeof cls[i]);
                        cls[i].cn.fd = cfd; cls[i].dead = 0;
                        cls[i].S.surfix = -1; cls[i].S.poolfd = -1;
                        ever++;
                        printf("WLSRV accepted fd=%d\n", cfd);
                        break;
                    }
                }
            }
        }
        pos++;
        if (ifd >= 0) {
            if (pf[pos].revents & POLLIN) on_input(ifd);
            pos++;
        }
        for (int i = 0; i < NCLI; i++) {
            if (cls[i].dead) continue;
            if (!(pf[pos].revents & (POLLIN | POLLHUP))) { pos++; continue; }
            pos++;
            int n = wl_fill(&cls[i].cn);
            if (n <= 0) { teardown(&cls[i]); continue; }
            int m;
            while ((m = wl_peel(&cls[i].cn, msg, sizeof msg)) > 0)
                dispatch(&cls[i]);
            if (m < 0) { printf("WLSRV FAIL wire\n"); return 1; }
            if (cls[i].dead) teardown(&cls[i]);
        }
    }
    // last-frame linger is gone with the clients — release whatever
    // scene surface state is still ours, then the node stays as
    // fs-visibility evidence.
    for (int i = 0; i < NCLI; i++) if (!cls[i].dead) teardown(&cls[i]);
    for (int i = 0; i < NSURF; i++)
        if (scs[i].live) { close(scs[i].fd); scs[i].live = 0; }
    printf("WLSRV done\n");
    return 0;
}
