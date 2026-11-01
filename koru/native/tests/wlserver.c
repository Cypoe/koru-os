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
};

// a session — one wl_client, our side-table of its routed objects
struct sess {
    int live;
    struct wl_client *cl;
    struct wl_listener dlistener;    // client-destroy hook
    struct wl_resource *seat, *ptr, *kbd, *wmb;
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
                    S->sc = t;
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
            long br = rect[2] && rect[3]
                ? syscall(K_SURF_BLIT, scs[S->surfix].fd,
                          wl_shm_buffer_get_data(shb), bstride, rect)
                : 0;
            int be = br < 0 ? errno : 0;
            long pr = br < 0 ? br
                : syscall(K_SURF_PRESENT, scs[S->surfix].fd,
                          rect[0], rect[1], rect[2], rect[3]);
            int pe = pr < 0 ? errno : 0;
            printf("WLSRV surf %ux%u dmg=%ux%u@%u,%u blit=%ld/%d "
                   "present=%ld/%d\n",
                   bw, bh, rect[2], rect[3], rect[0], rect[1],
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
static const struct wl_surface_interface surf_impl = {
    surf_destroy, surf_attach, surf_damage, surf_frame,
    surf_region, surf_region, surf_commit, surf_xform,
    surf_scale, surf_damage,   // damage_buffer shares the shape
};

static void surf_res_destroy(struct wl_resource *res) {
    struct rsurf *S = wl_resource_get_user_data(res);
    if (!S) return;
    if (S->surfix >= 0) {
        struct scsurf *s = &scs[S->surfix];
        if (s->live) {
            if (focus == (int)(s - scs)) focus = -1;
            if (drag == (int)(s - scs)) drag = -1;
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
static void comp_create_region(struct wl_client *cl,
                               struct wl_resource *res, uint32_t id) {
    // regions carry no behavior here — mint a valid resource so the
    // client's bookkeeping stays real.
    wl_resource_create(cl, &wl_region_interface, 1, id);
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

    // the real display: libwayland-server's object table, registry,
    // wire codec and event loop — the same code every compositor links.
    struct wl_display *dpy = wl_display_create();
    if (!dpy) { printf("WLSRV FAIL display\n"); return 1; }
    // registry ORDER is the gate's contract: names mint in create
    // order — comp, shm, seat, xdg.
    wl_global_create(dpy, &wl_compositor_interface, 4, NULL, comp_bind);
    wl_display_init_shm(dpy);               // the library's own wl_shm
    wl_global_create(dpy, &wl_seat_interface, 7, NULL, seat_bind);
    wl_global_create(dpy, &xdg_wm_base_interface, 1, NULL, wmb_bind);

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
