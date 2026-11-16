// wlserver.elf — a REAL compositor on REAL libwayland-server: the
// vendored 1.26 server sources (wayland-server.c + event-loop.c +
// wayland-shm.c) drive dispatch and demarshalling — this file only
// implements the resource callbacks, which is exactly the shape a
// wlroots/swayweston compositor has (libwayland + a policy body).
// The wire, the registry, wl_shm pool/buffer lifecycle, SCM_RIGHTS
// fd receive and client teardown are all the library's, not ours.
//
// The event loop is libwayland's epoll loop over {our listen fd,
// our input fd, every client conn}: nr518's evdev-shaped InEv
// records, hit-tested against the z-ordered scene list WE minted,
// become wl_pointer/wl_keyboard protocol. Placement is compositor
// policy — button-held or xdg_toplevel.move-requested drags ride
// nr519; the kernel routes nothing.
//
// Session shape: socket()+bind("wayland-1") mints S_IFSOCK through
// the fs view, listen()+accept() feed wl_client_create; globals are
// wl_global_create'd (wl_compositor v4, wl_shm via wl_display_init_shm,
// wl_seat v7, xdg_wm_base v1). The toplevel role handshake is real:
// an empty commit is answered by toplevel.configure +
// xsurface.configure(serial); a buffer commit before the ack is a
// loud violation whose pixels never ride the scene.
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include "wayland-server.h"
#include "wayland-server-protocol.h"
#include "xdg-shell-server-protocol.h"

#define WL_SOCK_NAME "wayland-1"

// koru scene seam — unchanged: 515 mints a *Surf as an fd projection,
// 516 blits client pixels into provider backing, 517 commits damage,
// 518 the input reader, 519 placement, 520 rect+extent readback.
// close(surffd) detaches — compositor lifetime, not a verb.
#define K_SURF_OPEN    515
#define K_SURF_BLIT    516
#define K_SURF_PRESENT 517
#define K_INPUT_OPEN   518
#define K_SURF_MOVE    519
#define K_SURF_INFO    520

#define NSES 4   // live sessions
#define NSURF 8  // scene surfaces across all sessions

// one provider event record — identical layout to kbd.InEv
struct inev { uint32_t kind, code, pressed; int32_t dx, dy; };

struct scene_geom { uint32_t x, y, w, h, sw, sh; };

// a placed scene surface — minted on its wl_surface's first lawful
// buffer commit
struct scsurf {
    int live;
    struct sess *ses;            // owning session
    struct wl_resource *sres;    // the client's wl_surface
    int fd;                      // the *Surf projection
    uint32_t *smap;              // mmap'd provider backing, if the seam
                                 // answered projectable — commit writes
                                 // land directly, no blit syscall
    uint32_t x, y, w, h;
};

// a client's surface record — hangs off the wl_surface resource
// (user_data); the xdg role objects + the ack contract live here.
struct rsurf {
    struct wl_resource *sres;        // the wl_surface itself
    struct wl_resource *xsurf, *top; // xdg role resources, if any
    struct wl_resource *buf, *cb;    // attached buffer + frame cb
    uint32_t confser, acked;
    int attached;
    int surfix;                      // scs[] index or -1
    struct scsurf *sc;
    int32_t dx, dy, dw, dh;          // pending damage union; dw<=0 = none
    // wl_subsurface role: a surface a parent composes at an offset.
    // sub_first chains the parent's children in list order (which IS
    // the z order place_above/place_below rearrange); sub_pending is
    // the sync-mode commit cache — applied on the parent's commit.
    struct rsurf *sub_parent, *sub_first, *sub_next;
    struct wl_resource *subres;      // the wl_subsurface resource
    int sub_sync;
    int32_t sub_dx, sub_dy;
    int sub_pending;
};

struct rsrc;                     // wl_data_source record — defined with
                                 // the data-device impl below

// a session — one wl_client, our side-table of its routed objects
struct sess {
    int live;
    struct wl_client *cl;
    struct wl_listener dlistener;    // client-destroy hook
    struct wl_resource *seat, *ptr, *kbd, *wmb;
    struct wl_resource *dd;          // wl_data_device for this seat
    struct rsrc *sel;                // the selection this client set
};

static struct sess ses[NSES];
static struct scsurf scs[NSURF];
static struct inev evs[16];
static uint32_t serial = 1;
static uint32_t px, py;
static uint32_t sw, sh;
static int focus = -1;
static int drag = -1;
static int ever_accepted;

static uint32_t msec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static struct sess *ses_of(struct wl_client *cl) {
    for (int i = 0; i < NSES; i++)
        if (ses[i].live && ses[i].cl == cl) return &ses[i];
    return NULL;
}

// ---- pointer/keyboard routing --------------------------------------
static void ptr_leave(struct sess *c, struct scsurf *s) {
    if (!c->ptr) return;
    wl_pointer_send_leave(c->ptr, serial++, s->sres);
    wl_pointer_send_frame(c->ptr);
}
static void ptr_enter(struct sess *c, struct scsurf *s) {
    if (!c->ptr) return;
    wl_pointer_send_enter(c->ptr, serial++, s->sres,
        wl_fixed_from_int((int32_t)(px - s->x)),
        wl_fixed_from_int((int32_t)(py - s->y)));
    wl_pointer_send_frame(c->ptr);
}
static void kbd_enter(struct sess *c, struct scsurf *s) {
    if (!c->kbd) return;
    struct wl_array keys;
    wl_array_init(&keys);
    wl_keyboard_send_enter(c->kbd, serial++, s->sres, &keys);
}
static void kbd_leave(struct sess *c, struct scsurf *s) {
    if (!c->kbd) return;
    wl_keyboard_send_leave(c->kbd, serial++, s->sres);
}

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
        ptr_leave(o->ses, o);
        kbd_leave(o->ses, o);
    }
    focus = n;
    if (focus >= 0) {
        struct scsurf *s = &scs[focus];
        ptr_enter(s->ses, s);
        kbd_enter(s->ses, s);
    }
}

static int on_input(int fd, uint32_t mask, void *data) {
    long n = read(fd, evs, sizeof evs);
    if (n < (long)sizeof evs[0]) return 0;
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
            // drag wins over focus — a held or client-requested grab
            // moves the surface; the scene re-hit-tests on release.
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
                if (s->ses->ptr) {
                    wl_pointer_send_motion(s->ses->ptr, msec(),
                        wl_fixed_from_int((int32_t)(px - s->x)),
                        wl_fixed_from_int((int32_t)(py - s->y)));
                    wl_pointer_send_frame(s->ses->ptr);
                }
            }
        } else if (e->kind == 2) {             // button
            uint32_t btn = e->code == 1 ? 0x110 :
                           e->code == 3 ? 0x111 : 0x112;
            if (e->pressed && focus >= 0) drag = focus;
            if (!e->pressed) { drag = -1; refocus(); }
            if (focus >= 0) {
                struct scsurf *s = &scs[focus];
                if (s->ses->ptr) {
                    wl_pointer_send_button(s->ses->ptr, serial++, msec(),
                                           btn, e->pressed);
                    wl_pointer_send_frame(s->ses->ptr);
                }
            }
        } else if (e->kind == 1) {             // key
            if (focus >= 0) {
                struct scsurf *s = &scs[focus];
                if (s->ses->kbd) {
                    wl_keyboard_send_key(s->ses->kbd, serial++, msec(),
                                         e->code, e->pressed);
                }
            }
        }
    }
    return 0;
}

// ---- wl_surface impl -------------------------------------------------
static void surf_destroy(struct wl_client *cl, struct wl_resource *res) {
    wl_resource_destroy(res);
}
static void surf_attach(struct wl_client *cl, struct wl_resource *res,
                        struct wl_resource *buffer, int32_t x, int32_t y) {
    struct rsurf *S = wl_resource_get_user_data(res);
    S->buf = buffer;                 // NULL buffer = unmap — attached
    S->attached = buffer != NULL;    // stays honest either way
}
static void surf_damage(struct wl_client *cl, struct wl_resource *res,
                        int32_t x, int32_t y, int32_t w, int32_t h) {
    // damage (surface-space) and damage_buffer (buffer-space) share this
    // handler — at scale 1 with no transform they coincide. The union is
    // the honest part: a swapchain ring means undamaged regions of the
    // newly attached buffer are stale, never re-presented.
    struct rsurf *S = wl_resource_get_user_data(res);
    if (w <= 0 || h <= 0) return;
    if (S->dw <= 0) { S->dx = x; S->dy = y; S->dw = w; S->dh = h; return; }
    int32_t x2 = S->dx + S->dw, y2 = S->dy + S->dh;
    if (x < S->dx) S->dx = x;
    if (y < S->dy) S->dy = y;
    if (x + w > x2) x2 = x + w;
    if (y + h > y2) y2 = y + h;
    S->dw = x2 - S->dx; S->dh = y2 - S->dy;
}
static void surf_frame(struct wl_client *cl, struct wl_resource *res,
                       uint32_t cbid) {
    struct rsurf *S = wl_resource_get_user_data(res);
    S->cb = wl_resource_create(cl, &wl_callback_interface, 1, cbid);
}
static void surf_region(struct wl_client *cl, struct wl_resource *res,
                        struct wl_resource *region) {}
static void surf_scale(struct wl_client *cl, struct wl_resource *res,
                       int32_t scale) {}
static void surf_xform(struct wl_client *cl, struct wl_resource *res,
                       int32_t transform) {}
// the commit's apply half — buffer blit, *Surf mint, damage, present,
// frame-done, release. A sync subsurface's commits replay through this
// when the PARENT commits; toplevels call it directly.
static void surf_apply(struct wl_client *cl, struct rsurf *S,
                       struct wl_resource *res) {
    struct wl_shm_buffer *shb =
        S->buf ? wl_shm_buffer_get(S->buf) : NULL;
    if (S->attached && shb &&
        !(S->xsurf && S->acked != S->confser)) {
        uint32_t bw = (uint32_t)wl_shm_buffer_get_width(shb);
        uint32_t bh = (uint32_t)wl_shm_buffer_get_height(shb);
        uint32_t bstride = (uint32_t)wl_shm_buffer_get_stride(shb);
        wl_shm_buffer_begin_access(shb);
        uint32_t magic = wl_shm_buffer_get_data(shb)
                       ? *(uint32_t *)wl_shm_buffer_get_data(shb) : 0;
        uint32_t tag = *(uint32_t *)((char *)wl_shm_buffer_get_data(shb) + 4);
        unsigned px0 = ((unsigned char *)wl_shm_buffer_get_data(shb))[256];
        printf("WLSRV magic=%08x tag=%08x px0=%02x\n", magic, tag, px0);
        {
            const char *bd = wl_shm_buffer_get_data(shb);
            uint32_t pr[6] = {0};
            unsigned want[6][2] = { {0,0},{1,0},{10,10},{40,40},
                                    {200,150},{640,360} };
            if (bd) {
                for (int pi = 0; pi < 6; pi++) {
                    unsigned wx = want[pi][0], wy = want[pi][1];
                    if (wx < bw && wy < bh)
                        pr[pi] = *(const uint32_t *)(bd + (size_t)wy * bstride
                                                     + (size_t)wx * 4);
                }
            }
            printf("WLSRV probe"
                   " p00=%08x p10=%08x p1010=%08x"
                   " p4040=%08x p200150=%08x p640360=%08x\n",
                   pr[0], pr[1], pr[2], pr[3], pr[4], pr[5]);
        }
        if (S->surfix < 0) {
            for (int i = 0; i < NSURF && S->surfix < 0; i++)
                if (!scs[i].live) S->surfix = i;
            if (S->surfix >= 0) {
                struct scsurf *t = &scs[S->surfix];
                int f = (int)syscall(K_SURF_OPEN, bw, bh);
                if (f >= 0) {
                    t->live = 1; t->ses = ses_of(cl);
                    t->sres = res; t->fd = f;
                    t->w = bw; t->h = bh;
                    // the projectable-backing arm: mmap the *Surf fd and
                    // commit writes land straight on provider memory;
                    // MAP_FAILED leaves smap NULL and the blit syscall
                    // stays the honest path.
                    void *m = mmap(NULL, (size_t)bw * bh * 4,
                                   PROT_READ | PROT_WRITE, MAP_SHARED,
                                   f, 0);
                    t->smap = m == MAP_FAILED ? NULL : m;
                    S->sc = t;
                    if (S->sub_parent && S->sub_parent->sc) {
                        // a subsurface composes at the parent's own
                        // position + its set_position offset — the
                        // tile formula is for toplevels.
                        t->x = (uint32_t)((int32_t)S->sub_parent->sc->x
                                          + S->sub_dx);
                        t->y = (uint32_t)((int32_t)S->sub_parent->sc->y
                                          + S->sub_dy);
                    } else {
                        t->x = 40 + 100 * (uint32_t)S->surfix;
                        t->y = 40 + 100 * (uint32_t)S->surfix;
                    }
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
            // only the declared damage is fresh in this buffer — blit
            // that rect onto the accumulated backing; no damage declared
            // falls back to the whole buffer (legacy clients).
            int32_t rx = 0, ry = 0, rw = (int32_t)bw, rh = (int32_t)bh;
            if (S->dw > 0) {
                rx = S->dx; ry = S->dy; rw = S->dw; rh = S->dh;
                if (rx < 0) { rw += rx; rx = 0; }
                if (ry < 0) { rh += ry; ry = 0; }
                if (rx + rw > (int32_t)bw) rw = (int32_t)bw - rx;
                if (ry + rh > (int32_t)bh) rh = (int32_t)bh - ry;
            }
            S->dw = 0; // damage consumed by this commit
            uint32_t rect[4] = { (uint32_t)rx, (uint32_t)ry,
                                 (uint32_t)(rw > 0 ? rw : 0),
                                 (uint32_t)(rh > 0 ? rh : 0) };
            struct scsurf *sc = &scs[S->surfix];
            long br = 0;
            if (rect[2] && rect[3]) {
                if (sc->smap) {
                    // projectable backing — copy the damaged rows
                    // straight into provider memory; present() is the
                    // commit point either way.
                    const char *src = wl_shm_buffer_get_data(shb);
                    for (uint32_t row = 0; row < rect[3]; row++)
                        memcpy(sc->smap + (rect[1] + row) * sc->w + rect[0],
                               src + (size_t)(rect[1] + row) * bstride
                                   + (size_t)rect[0] * 4,
                               (size_t)rect[2] * 4);
                } else {
                    br = syscall(K_SURF_BLIT, sc->fd,
                                 wl_shm_buffer_get_data(shb), bstride, rect);
                }
            }
            int be = br < 0 ? errno : 0;
            long pr = br < 0 ? br
                : syscall(K_SURF_PRESENT, scs[S->surfix].fd,
                          rect[0], rect[1], rect[2], rect[3]);
            int pe = pr < 0 ? errno : 0;
            printf("WLSRV surf %ux%u smap=%d dmg=%ux%u@%u,%u blit=%ld/%d "
                   "present=%ld/%d\n",
                   bw, bh, sc->smap != NULL,
                   rect[2], rect[3], rect[0], rect[1],
                   br, be, pr, pe);
        }
        wl_shm_buffer_end_access(shb);
    }
    if (S->cb) {
        wl_callback_send_done(S->cb, 42);
        wl_resource_destroy(S->cb);
        S->cb = NULL;
    }
    if (S->buf && S->attached) {
        wl_buffer_send_release(S->buf);
    }
}

static void surf_commit(struct wl_client *cl, struct wl_resource *res) {
    struct rsurf *S = wl_resource_get_user_data(res);

    if (S->xsurf && S->top && !S->confser) {
        // the role handshake: an xdg client performs an initial
        // buffer-less commit after get_toplevel; the compositor's
        // answer is toplevel.configure (0,0 = client's call) followed
        // by xsurface.configure(serial). The buffer commit after it
        // MUST carry the ack.
        struct wl_array st;
        wl_array_init(&st);
        xdg_toplevel_send_configure(S->top, 0, 0, &st);
        xdg_surface_send_configure(S->xsurf, serial);
        printf("WLSRV toplevel configure ser=%u\n", serial);
        S->confser = serial++;
    }
    if (S->xsurf && S->confser && S->attached &&
        S->acked != S->confser) {
        printf("WLSRV unacked commit (ack=%u want=%u)\n",
               S->acked, S->confser);
    }

    if (S->sub_parent && S->sub_sync) {
        // synchronized subsurface: the commit caches, the parent's own
        // commit is the apply point — the protocol's whole sync flag.
        S->sub_pending = 1;
        printf("WLSRV sub commit sync-deferred\n");
        return;
    }
    surf_apply(cl, S, res);
    for (struct rsurf *t = S->sub_first; t; t = t->sub_next) {
        if (t->sub_pending) {
            t->sub_pending = 0;
            surf_apply(cl, t, t->sres);
        }
    }
}
static const struct wl_surface_interface surf_impl = {
    surf_destroy, surf_attach, surf_damage, surf_frame,
    surf_region, surf_region, surf_commit, surf_xform,
    surf_scale, surf_damage,   // damage_buffer shares the shape
};

static void surf_res_destroy(struct wl_resource *res) {
    struct rsurf *S = wl_resource_get_user_data(res);
    if (!S) return;
    if (S->sub_parent) {
        // detach from the parent's sub list — a dead link is a dangling
        // commit replay, not just bookkeeping
        struct rsurf **pp = &S->sub_parent->sub_first;
        while (*pp && *pp != S) pp = &(*pp)->sub_next;
        if (*pp == S) *pp = S->sub_next;
        S->sub_parent = NULL;
    }
    if (S->surfix >= 0) {
        struct scsurf *s = &scs[S->surfix];
        if (s->live) {
            if (focus == (int)(s - scs)) focus = -1;
            if (drag == (int)(s - scs)) drag = -1;
            if (s->smap) munmap(s->smap, (size_t)s->w * s->h * 4);
            close(s->fd);
            s->live = 0;
            printf("WLSRV surf released slot=%d\n", (int)(s - scs));
        }
        S->surfix = -1;
    }
    free(S);
}

// ---- wl_compositor impl ----------------------------------------------
static void comp_create_surface(struct wl_client *cl,
                                struct wl_resource *res, uint32_t id) {
    struct rsurf *S = calloc(1, sizeof *S);
    S->surfix = -1;
    struct wl_resource *sres =
        wl_resource_create(cl, &wl_surface_interface,
                           wl_resource_get_version(res), id);
    S->sres = sres;
    wl_resource_set_implementation(sres, &surf_impl, S,
                                 surf_res_destroy);
}
// regions carry no behavior in this compositor — but the resource must
// still carry a REAL implementation: a NULL impl is libwayland's abort
// path, so add/subtract land as accepted no-ops.
static void region_add(struct wl_client *cl, struct wl_resource *res,
                       int32_t x, int32_t y, int32_t w, int32_t h) {}
static void region_sub(struct wl_client *cl, struct wl_resource *res,
                       int32_t x, int32_t y, int32_t w, int32_t h) {}
static void region_destroy(struct wl_client *cl, struct wl_resource *res) {
    wl_resource_destroy(res);
}
static const struct wl_region_interface region_impl = {
    region_destroy, region_add, region_sub,
};
static void comp_create_region(struct wl_client *cl,
                               struct wl_resource *res, uint32_t id) {
    struct wl_resource *rr =
        wl_resource_create(cl, &wl_region_interface, 1, id);
    wl_resource_set_implementation(rr, &region_impl, NULL, NULL);
}
static const struct wl_compositor_interface comp_impl = {
    comp_create_surface, comp_create_region,
};
static void comp_bind(struct wl_client *cl, void *data,
                      uint32_t version, uint32_t id) {
    struct wl_resource *res =
        wl_resource_create(cl, &wl_compositor_interface,
                           version > 4 ? 4 : version, id);
    wl_resource_set_implementation(res, &comp_impl, NULL, NULL);
}

// ---- wl_subcompositor impl -------------------------------------------
// Real surfaces composited at a parent-relative offset — foot binds the
// global unconditionally (its overlay/search box are subsurfaces), and
// a bare global answer would be a lie: the objects mint real records,
// sync commits really defer to the parent's, and the z-list really
// reorders. The *Surf presentation at parent+offset rides the same
// seam a toplevel does.
static void sub_destroy(struct wl_client *cl, struct wl_resource *res) {
    struct rsurf *S = wl_resource_get_user_data(res);
    if (S) {
        S->subres = NULL;
        if (S->sub_parent) {
            struct rsurf **pp = &S->sub_parent->sub_first;
            while (*pp && *pp != S) pp = &(*pp)->sub_next;
            if (*pp == S) *pp = S->sub_next;
            S->sub_parent = NULL;
        }
    }
    wl_resource_destroy(res);
}
static void sub_set_position(struct wl_client *cl,
                             struct wl_resource *res,
                             int32_t x, int32_t y) {
    struct rsurf *S = wl_resource_get_user_data(res);
    if (!S) return;
    S->sub_dx = x; S->sub_dy = y;
    // live surfaces re-place immediately — desync clients see it now;
    // sync clients see it at the next parent commit either way, which
    // is the same picture the spec promises.
    if (S->sc && S->sub_parent && S->sub_parent->sc) {
        uint32_t nx = (uint32_t)((int32_t)S->sub_parent->sc->x + x);
        uint32_t ny = (uint32_t)((int32_t)S->sub_parent->sc->y + y);
        syscall(K_SURF_MOVE, S->sc->fd, nx, ny);
        S->sc->x = nx; S->sc->y = ny;
    }
}
static void sub_restack(struct wl_client *cl, struct wl_resource *res,
                        struct wl_resource *sibling, int below) {
    // sibling may be the parent surface itself (spec: a valid ref) —
    // below-parent means bottom of the list, above-parent the top.
    struct rsurf *S = wl_resource_get_user_data(res);
    if (!S || !S->sub_parent) return;
    struct rsurf *R = sibling
        ? wl_resource_get_user_data(sibling) : NULL;
    struct rsurf *P = S->sub_parent;
    // detach first — the list is the z-order
    struct rsurf **pp = &P->sub_first;
    while (*pp && *pp != S) pp = &(*pp)->sub_next;
    if (*pp == S) *pp = S->sub_next;
    S->sub_next = NULL;
    if (R == P || !R) {
        // parent itself: below -> head, above -> tail
        if (below) {
            S->sub_next = P->sub_first;
            P->sub_first = S;
        } else {
            struct rsurf **tail = &P->sub_first;
            while (*tail) tail = &(*tail)->sub_next;
            *tail = S;
        }
        return;
    }
    // sibling must share our parent — protocol's own validity check
    if (R->sub_parent != P) {
        wl_resource_post_error(res,
            WL_SUBCOMPOSITOR_ERROR_BAD_SURFACE,
            "sibling is not a sibling");
        return;
    }
    if (below) {
        // insert S before R
        struct rsurf **q = &P->sub_first;
        while (*q && *q != R) q = &(*q)->sub_next;
        S->sub_next = *q;
        *q = S;
    } else {
        S->sub_next = R->sub_next;
        R->sub_next = S;
    }
}
static void sub_place_above(struct wl_client *cl,
                            struct wl_resource *res,
                            struct wl_resource *sibling) {
    sub_restack(cl, res, sibling, 0);
}
static void sub_place_below(struct wl_client *cl,
                            struct wl_resource *res,
                            struct wl_resource *sibling) {
    sub_restack(cl, res, sibling, 1);
}
static void sub_set_sync(struct wl_client *cl,
                         struct wl_resource *res) {
    struct rsurf *S = wl_resource_get_user_data(res);
    if (S) S->sub_sync = 1;
}
static void sub_set_desync(struct wl_client *cl,
                           struct wl_resource *res) {
    struct rsurf *S = wl_resource_get_user_data(res);
    if (S) S->sub_sync = 0;
}
static const struct wl_subsurface_interface sub_impl = {
    sub_destroy, sub_set_position, sub_place_above, sub_place_below,
    sub_set_sync, sub_set_desync,
};

static void subcomp_destroy(struct wl_client *cl,
                            struct wl_resource *res) {
    wl_resource_destroy(res);
}
static void subcomp_get_subsurface(struct wl_client *cl,
                                   struct wl_resource *res, uint32_t id,
                                   struct wl_resource *surface,
                                   struct wl_resource *parent) {
    struct rsurf *S = wl_resource_get_user_data(surface);
    struct rsurf *P = wl_resource_get_user_data(parent);
    if (!S || !P || S == P) {
        wl_resource_post_error(res,
            WL_SUBCOMPOSITOR_ERROR_BAD_PARENT,
            "surface cannot be its own parent");
        return;
    }
    if (S->sub_parent || S->xsurf || S->top) {
        wl_resource_post_error(res,
            WL_SUBCOMPOSITOR_ERROR_BAD_SURFACE,
            "surface already has a role");
        return;
    }
    S->sub_parent = P;
    S->sub_sync = 1; // spec default — commits defer to the parent's
    // append at the tail — a new sub sits at the top of the stack
    struct rsurf **tail = &P->sub_first;
    while (*tail) tail = &(*tail)->sub_next;
    *tail = S;
    S->sub_next = NULL;
    struct wl_resource *sres =
        wl_resource_create(cl, &wl_subsurface_interface, 1, id);
    S->subres = sres;
    wl_resource_set_implementation(sres, &sub_impl, S, NULL);
    printf("WLSRV subsurface minted\n");
}
static const struct wl_subcompositor_interface subcomp_impl = {
    subcomp_destroy, subcomp_get_subsurface,
};
static void subcomp_bind(struct wl_client *cl, void *data,
                         uint32_t version, uint32_t id) {
    struct wl_resource *res =
        wl_resource_create(cl, &wl_subcompositor_interface,
                           version > 1 ? 1 : version, id);
    wl_resource_set_implementation(res, &subcomp_impl, NULL, NULL);
    printf("WLSRV subcompositor bound\n");
}

// ---- wl_data_device_manager impl -------------------------------------
// The clipboard chain: manager -> data_source (a client's offered
// mimes) + data_device (per seat, holds the selection) -> data_offer
// (the cross-client handle). receive() relays the requester's fd into
// the source's `send` event — the bytes travel source-client ->
// requester-client through the same SCM_RIGHTS channel shm pools do.
// With one client nothing is ever offered, which is the honest shape
// of a sole selection owner.

struct rsrc {                    // a live wl_data_source
    struct wl_resource *res;
    struct sess *ses;
    char mimes[8][64];
    int nmime;
    uint32_t actions;
    struct rsrc *next;
};
static struct rsrc *sources;

struct roffer {                  // a live wl_data_offer
    struct wl_resource *res;
    struct rsrc *src;
    char accepted[64];
    struct roffer *next;
};
static struct roffer *offers;

static void src_offer(struct wl_client *cl, struct wl_resource *res,
                      const char *mime) {
    struct rsrc *s = wl_resource_get_user_data(res);
    if (!s || s->nmime >= 8 || !mime) return;
    snprintf(s->mimes[s->nmime], 64, "%s", mime);
    s->nmime++;
}
static void src_set_actions(struct wl_client *cl,
                            struct wl_resource *res, uint32_t a) {
    struct rsrc *s = wl_resource_get_user_data(res);
    if (s) s->actions = a;
}
static void src_destroy(struct wl_client *cl, struct wl_resource *res) {
    struct rsrc *s = wl_resource_get_user_data(res);
    if (s && s->ses && s->ses->sel == s) s->ses->sel = NULL;
    wl_resource_destroy(res);
}
static const struct wl_data_source_interface src_impl = {
    src_offer, src_destroy, src_set_actions,
};

static void offer_accept(struct wl_client *cl, struct wl_resource *res,
                         uint32_t serial, const char *mime) {
    struct roffer *o = wl_resource_get_user_data(res);
    if (o && mime) snprintf(o->accepted, 64, "%s", mime);
}
static void offer_receive(struct wl_client *cl, struct wl_resource *res,
                          const char *mime, int32_t fd) {
    // the protocol's real relay: the requester's fd becomes the
    // source's send target — server does no byte-copying at all.
    struct roffer *o = wl_resource_get_user_data(res);
    if (o && o->src && o->src->res) {
        wl_data_source_send_send(o->src->res, mime ? mime : "", fd);
    }
    close(fd);
}
static void offer_destroy(struct wl_client *cl, struct wl_resource *res) {
    struct roffer *o = wl_resource_get_user_data(res);
    if (o) { o->src = NULL; o->res = NULL; }
    wl_resource_destroy(res);
}
static void offer_finish(struct wl_client *cl, struct wl_resource *res) {}
static void offer_set_actions(struct wl_client *cl,
                              struct wl_resource *res,
                              uint32_t da, uint32_t pa) {}
static const struct wl_data_offer_interface offer_impl = {
    offer_accept, offer_receive, offer_destroy, offer_finish,
    offer_set_actions,
};

static void dd_start_drag(struct wl_client *cl, struct wl_resource *res,
                          struct wl_resource *source,
                          struct wl_resource *origin,
                          struct wl_resource *icon, uint32_t serial) {
    // DnD gesture bookkeeping — recorded, not played: the pointer
    // routing that would carry a drag lives in the input seam and
    // this rung's clients never start one.
}
static void dd_set_selection(struct wl_client *cl, struct wl_resource *res,
                             struct wl_resource *source, uint32_t ser) {
    struct sess *me = ses_of(cl);
    struct rsrc *src = source ? wl_resource_get_user_data(source) : NULL;
    if (me) me->sel = src;
    printf("WLSRV selection set mimes=%d\n", src ? src->nmime : -1);
    // every OTHER live session's device gets a fresh offer carrying
    // the source's real mime list
    for (int i = 0; i < NSES; i++) {
        if (!ses[i].live || &ses[i] == me || !ses[i].dd) continue;
        struct roffer *o = calloc(1, sizeof *o);
        if (!o) continue;
        o->src = src;
        // server-pushed object: id 0 lets the data_offer event's
        // new_id assign the wire id at send time
        o->res = wl_resource_create(ses[i].cl,
                    &wl_data_offer_interface, 1, 0);
        if (!o->res) { free(o); continue; }
        wl_resource_set_implementation(o->res, &offer_impl, o, NULL);
        o->next = offers; offers = o;
        wl_data_device_send_data_offer(ses[i].dd, o->res);
        if (src) {
            for (int m = 0; m < src->nmime; m++)
                wl_data_offer_send_offer(o->res, src->mimes[m]);
        }
        wl_data_device_send_selection(ses[i].dd, o->res);
    }
}
static void dd_release(struct wl_client *cl, struct wl_resource *res) {
    struct sess *c = ses_of(cl);
    if (c) c->dd = NULL;
    wl_resource_destroy(res);
}
static const struct wl_data_device_interface dd_impl = {
    dd_start_drag, dd_set_selection, dd_release,
};
static void ddm_create_source(struct wl_client *cl,
                              struct wl_resource *res, uint32_t id) {
    struct rsrc *s = calloc(1, sizeof *s);
    if (!s) return;
    s->ses = ses_of(cl);
    s->res = wl_resource_create(cl, &wl_data_source_interface,
                                wl_resource_get_version(res), id);
    wl_resource_set_implementation(s->res, &src_impl, s, NULL);
    s->next = sources; sources = s;
    printf("WLSRV datasource minted\n");
}
static void ddm_get_device(struct wl_client *cl, struct wl_resource *res,
                           uint32_t id, struct wl_resource *seat) {
    struct wl_resource *dd =
        wl_resource_create(cl, &wl_data_device_interface,
                           wl_resource_get_version(res), id);
    wl_resource_set_implementation(dd, &dd_impl, NULL, NULL);
    struct sess *c = ses_of(cl);
    if (c) c->dd = dd;
    printf("WLSRV datadevice minted\n");
}
static const struct wl_data_device_manager_interface ddm_impl = {
    ddm_create_source, ddm_get_device,
};
static void ddm_bind(struct wl_client *cl, void *data,
                     uint32_t version, uint32_t id) {
    struct wl_resource *res =
        wl_resource_create(cl, &wl_data_device_manager_interface,
                           version > 3 ? 3 : version, id);
    wl_resource_set_implementation(res, &ddm_impl, NULL, NULL);
}

// ---- wl_output impl --------------------------------------------------
// The monitor answer foot demands: real scanout facts, learned from the
// scene extent probe at startup — never a hardcoded resolution.
static void out_release(struct wl_client *cl, struct wl_resource *res) {
    wl_resource_destroy(res);
}
static const struct wl_output_interface out_impl = { out_release };
static void out_bind(struct wl_client *cl, void *data,
                     uint32_t version, uint32_t id) {
    struct wl_resource *res =
        wl_resource_create(cl, &wl_output_interface,
                           version > 4 ? 4 : version, id);
    wl_resource_set_implementation(res, &out_impl, NULL, NULL);
    wl_output_send_geometry(res, 0, 0, 0, 0,
                            WL_OUTPUT_SUBPIXEL_NONE, "koru-os",
                            "virtio-gpu", WL_OUTPUT_TRANSFORM_NORMAL);
    wl_output_send_mode(res, WL_OUTPUT_MODE_CURRENT |
                        WL_OUTPUT_MODE_PREFERRED,
                        (int32_t)sw, (int32_t)sh, 60000);
    if (version >= 2) wl_output_send_scale(res, 1);
    if (version >= 4) {
        wl_output_send_name(res, "koru-scanout0");
        wl_output_send_description(res, "koru-os virtio-gpu scanout");
    }
    wl_output_send_done(res);
    printf("WLSRV output %ux%u@60\n", sw, sh);
}

// ---- wl_seat impl ------------------------------------------------------
static void ptr_set_cursor(struct wl_client *cl, struct wl_resource *res,
                           uint32_t serial, struct wl_resource *surface,
                           int32_t hx, int32_t hy) {}
static void ptr_release(struct wl_client *cl, struct wl_resource *res) {
    struct sess *c = ses_of(cl);
    if (c) c->ptr = NULL;
    wl_resource_destroy(res);
}
static const struct wl_pointer_interface ptr_impl = {
    ptr_set_cursor, ptr_release,
};
static void kbd_release(struct wl_client *cl, struct wl_resource *res) {
    struct sess *c = ses_of(cl);
    if (c) c->kbd = NULL;
    wl_resource_destroy(res);
}
static const struct wl_keyboard_interface kbd_impl = { kbd_release };

static const char KEYMAP[] =
    "xkb_keymap {\n"
    "  xkb_keycodes \"evdev\" { minimum = 8; maximum = 255; };\n"
    "  xkb_types \"default\" { };\n"
    "  xkb_compat \"default\" { };\n"
    "  xkb_symbols \"default\" { };\n"
    "};\n";

static void seat_get_pointer(struct wl_client *cl, struct wl_resource *res,
                             uint32_t id) {
    struct sess *c = ses_of(cl);
    struct wl_resource *p =
        wl_resource_create(cl, &wl_pointer_interface,
                           wl_resource_get_version(res), id);
    wl_resource_set_implementation(p, &ptr_impl, NULL, NULL);
    if (c) c->ptr = p;
}
static void seat_get_keyboard(struct wl_client *cl, struct wl_resource *res,
                              uint32_t id) {
    struct sess *c = ses_of(cl);
    struct wl_resource *k =
        wl_resource_create(cl, &wl_keyboard_interface,
                           wl_resource_get_version(res), id);
    wl_resource_set_implementation(k, &kbd_impl, NULL, NULL);
    if (c) c->kbd = k;
    // the keymap is protocol-required before keys — a real memfd
    // rides the wire like it does under every real compositor.
    int mfd = (int)syscall(319, "xkb", 0);
    if (mfd >= 0) {
        int sz = (int)sizeof(KEYMAP) - 1;
        write(mfd, KEYMAP, sz);
        wl_keyboard_send_keymap(k, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,
                                mfd, (uint32_t)sz);
        close(mfd);
    }
}
static void seat_get_touch(struct wl_client *cl, struct wl_resource *res,
                           uint32_t id) {
    wl_resource_create(cl, &wl_touch_interface,
                       wl_resource_get_version(res), id);
}
static void seat_release(struct wl_client *cl, struct wl_resource *res) {
    struct sess *c = ses_of(cl);
    if (c && c->seat == res) c->seat = NULL;
    wl_resource_destroy(res);
}
static const struct wl_seat_interface seat_impl = {
    seat_get_pointer, seat_get_keyboard, seat_get_touch, seat_release,
};
static void seat_bind(struct wl_client *cl, void *data,
                      uint32_t version, uint32_t id) {
    struct sess *c = ses_of(cl);
    struct wl_resource *res =
        wl_resource_create(cl, &wl_seat_interface,
                           version > 7 ? 7 : version, id);
    wl_resource_set_implementation(res, &seat_impl, NULL, NULL);
    if (c) c->seat = res;
    wl_seat_send_capabilities(res, WL_SEAT_CAPABILITY_POINTER |
                                   WL_SEAT_CAPABILITY_KEYBOARD);
    printf("WLSRV seat caps\n");
}

// ---- xdg_shell impl ----------------------------------------------------
static void wmb_destroy(struct wl_client *cl, struct wl_resource *res) {
    struct sess *c = ses_of(cl);
    if (c && c->wmb == res) c->wmb = NULL;
    wl_resource_destroy(res);
}
static void wmb_positioner(struct wl_client *cl, struct wl_resource *res,
                           uint32_t id) {
    // popups unimplemented — a valid resource keeps the client's
    // object table real without dispatch.
    wl_resource_create(cl, &xdg_positioner_interface, 1, id);
}
static void wmb_pong(struct wl_client *cl, struct wl_resource *res,
                     uint32_t ser) {
    printf("WLSRV pong %u\n", ser);
}

static void xsurf_destroy(struct wl_client *cl, struct wl_resource *res) {
    struct rsurf *S = wl_resource_get_user_data(res);
    if (S) S->xsurf = NULL;
    wl_resource_destroy(res);
}
static void xsurf_ack(struct wl_client *cl, struct wl_resource *res,
                    uint32_t ser) {
    struct rsurf *S = wl_resource_get_user_data(res);
    S->acked = ser;
    printf("WLSRV ack %u\n", ser);
}
static void xsurf_geom(struct wl_client *cl, struct wl_resource *res,
                       int32_t x, int32_t y, int32_t w, int32_t h) {}

static void top_destroy(struct wl_client *cl, struct wl_resource *res) {
    struct rsurf *S = wl_resource_get_user_data(res);
    if (S) S->top = NULL;
    wl_resource_destroy(res);
}
static void top_noop(struct wl_client *cl, struct wl_resource *res) {}
static void top_parent(struct wl_client *cl, struct wl_resource *res,
                       struct wl_resource *parent) {}
static void top_title(struct wl_client *cl, struct wl_resource *res,
                      const char *title) {
    printf("WLSRV title %s\n", title);
}
static void top_appid(struct wl_client *cl, struct wl_resource *res,
                      const char *app_id) {
    printf("WLSRV appid %s\n", app_id);
}
static void top_menu(struct wl_client *cl, struct wl_resource *res,
                     struct wl_resource *seat, uint32_t ser,
                     int32_t x, int32_t y) {}
static void top_move(struct wl_client *cl, struct wl_resource *res,
                     struct wl_resource *seat, uint32_t ser) {
    // the REAL interactive-move request: the toplevel asks the
    // compositor to start a pointer grab — ours binds the grab to
    // this surface until the next release.
    struct rsurf *S = wl_resource_get_user_data(res);
    if (S && S->surfix >= 0) {
        drag = S->surfix;
        printf("WLSRV tl-move slot=%d\n", drag);
    }
}
static void top_resize(struct wl_client *cl, struct wl_resource *res,
                       struct wl_resource *seat, uint32_t ser,
                       uint32_t edges) {}
static void top_size(struct wl_client *cl, struct wl_resource *res,
                     int32_t w, int32_t h) {}
static void top_full(struct wl_client *cl, struct wl_resource *res,
                     struct wl_resource *output) {}
static const struct xdg_toplevel_interface top_impl = {
    top_destroy, top_parent, top_title, top_appid, top_menu,
    top_move, top_resize, top_size, top_size, top_noop, top_noop,
    top_full, top_noop, top_noop,
};

static void xsurf_get_toplevel(struct wl_client *cl,
                               struct wl_resource *res, uint32_t id) {
    struct rsurf *S = wl_resource_get_user_data(res);
    struct wl_resource *t =
        wl_resource_create(cl, &xdg_toplevel_interface, 1, id);
    wl_resource_set_implementation(t, &top_impl, S, NULL);
    S->top = t;
}
static void xsurf_get_popup(struct wl_client *cl, struct wl_resource *res,
                            uint32_t id, struct wl_resource *parent,
                            struct wl_resource *pos) {
    wl_resource_create(cl, &xdg_popup_interface, 1, id);
}
static const struct xdg_surface_interface xsurf_impl = {
    xsurf_destroy, xsurf_get_toplevel, xsurf_get_popup,
    xsurf_geom, xsurf_ack,
};

static void wmb_get_xsurf(struct wl_client *cl, struct wl_resource *res,
                          uint32_t id, struct wl_resource *surface) {
    struct rsurf *S = wl_resource_get_user_data(surface);
    if (!S) {
        // a foreign object can't take a role — loud, like the
        // protocol's role error, not silent.
        printf("WLSRV xsurf bad-surface\n");
        return;
    }
    struct wl_resource *x =
        wl_resource_create(cl, &xdg_surface_interface, 1, id);
    wl_resource_set_implementation(x, &xsurf_impl, S, NULL);
    S->xsurf = x;
    printf("WLSRV xsurf oid=%u\n", id);
}
static const struct xdg_wm_base_interface wmb_impl = {
    wmb_destroy, wmb_positioner, wmb_get_xsurf, wmb_pong,
};
static void wmb_bind(struct wl_client *cl, void *data,
                     uint32_t version, uint32_t id) {
    struct sess *c = ses_of(cl);
    struct wl_resource *res =
        wl_resource_create(cl, &xdg_wm_base_interface, 1, id);
    wl_resource_set_implementation(res, &wmb_impl, NULL, NULL);
    if (c) c->wmb = res;
    // liveness is a channel: ping at bind; a dead client never pongs.
    xdg_wm_base_send_ping(res, serial);
    printf("WLSRV ping %u\n", serial);
    serial++;
}

// ---- session lifecycle -------------------------------------------------
static void client_gone(struct wl_listener *l, void *data) {
    struct sess *c = wl_container_of(l, c, dlistener);
    for (int i = 0; i < NSURF; i++) {
        struct scsurf *s = &scs[i];
        if (s->live && s->ses == c) {
            if (focus == i) focus = -1;
            if (drag == i) drag = -1;
            close(s->fd);        // detach — comp repaints the rect
            s->live = 0;
            printf("WLSRV surf released slot=%d\n", i);
        }
    }
    c->live = 0;
    printf("WLSRV EOS\n");
}

static int on_accept(int fd, uint32_t mask, void *data) {
    struct wl_display *dpy = data;
    int cfd = accept(fd, NULL, NULL);
    if (cfd < 0) return 0;
    for (int i = 0; i < NSES; i++) {
        if (!ses[i].live) {
            struct wl_client *cl = wl_client_create(dpy, cfd);
            if (!cl) { close(cfd); return 0; }
            memset(&ses[i], 0, sizeof ses[i]);
            ses[i].live = 1;
            ses[i].cl = cl;
            ses[i].dlistener.notify = client_gone;
            wl_client_add_destroy_listener(cl, &ses[i].dlistener);
            ever_accepted = 1;
            printf("WLSRV accepted fd=%d\n", cfd);
            return 0;
        }
    }
    close(cfd);
    return 0;
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
    unlink(WL_SOCK_NAME);
    if (bind(lfd, (struct sockaddr *)&sa, sizeof(sa.sun_family) + strlen(WL_SOCK_NAME) + 1) < 0) {
        printf("WLSRV FAIL bind\n"); return 1;
    }
    if (listen(lfd, 4) < 0) { printf("WLSRV FAIL listen\n"); return 1; }
    printf("WLSRV bound %s\n", WL_SOCK_NAME);

    int ifd = (int)syscall(K_INPUT_OPEN);
    int iopen = errno;
    printf("WLSRV input %s e=%d\n", ifd >= 0 ? "open" : "refused",
           ifd >= 0 ? 0 : iopen);
    px = py = 0;

    // the scanout extent for wl_output's answer — a throwaway *Surf is
    // the only extent door the seam offers. The scene reports its own
    // facts; nothing here is hardcoded.
    {
        int pf = (int)syscall(K_SURF_OPEN, 1, 1);
        if (pf >= 0) {
            struct scene_geom g;
            if (syscall(K_SURF_INFO, pf, &g) == 0) { sw = g.sw; sh = g.sh; }
            close(pf);
        }
    }

    // the real display: libwayland-server's object table, registry,
    // wire codec and event loop — the same code every compositor links.
    struct wl_display *dpy = wl_display_create();
    if (!dpy) { printf("WLSRV FAIL display\n"); return 1; }
    // registry ORDER is the gate's contract: names mint in create
    // order — comp, shm, seat, xdg own 1..4 for the existing rows;
    // the real-desktop globals append after them.
    wl_global_create(dpy, &wl_compositor_interface, 4, NULL, comp_bind);
    wl_display_init_shm(dpy);               // the library's own wl_shm
    wl_global_create(dpy, &wl_seat_interface, 7, NULL, seat_bind);
    wl_global_create(dpy, &xdg_wm_base_interface, 1, NULL, wmb_bind);
    wl_global_create(dpy, &wl_subcompositor_interface, 1, NULL,
                     subcomp_bind);
    wl_global_create(dpy, &wl_data_device_manager_interface, 3, NULL,
                     ddm_bind);
    wl_global_create(dpy, &wl_output_interface, 4, NULL, out_bind);

    struct wl_event_loop *loop = wl_display_get_event_loop(dpy);
    wl_event_loop_add_fd(loop, lfd, WL_EVENT_READABLE, on_accept, dpy);
    if (ifd >= 0)
        wl_event_loop_add_fd(loop, ifd, WL_EVENT_READABLE, on_input, NULL);

    // quiescence policy: before any client the wait is unbounded (a
    // compositor does not exit because nobody arrived yet); once
    // clients have come and ALL have gone, a beat of silence ends it —
    // the gate needs a reachable exit.
    for (;;) {
        int live = 0;
        for (int i = 0; i < NSES; i++) if (ses[i].live) live++;
        int pr = wl_event_loop_dispatch(loop,
                    (ever_accepted && live == 0) ? 1500 : -1);
        wl_display_flush_clients(dpy);
        // ses[] mutates INSIDE dispatch (accept mints, EOS frees) —
        // recount after it or the first client reads as never-here.
        live = 0;
        for (int i = 0; i < NSES; i++) if (ses[i].live) live++;
        if (ever_accepted && live == 0 && pr == 0) break;
        if (pr < 0 && errno != EINTR) break;
    }
    for (int i = 0; i < NSURF; i++)
        if (scs[i].live) { close(scs[i].fd); scs[i].live = 0; }
    wl_display_destroy_clients(dpy);
    wl_display_destroy(dpy);
    printf("WLSRV done\n");
    return 0;
}
