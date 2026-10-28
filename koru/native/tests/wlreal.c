// wlreal.elf — a REAL libwayland client: the vendored libwayland-1.26
// (connection.c/wayland-client.c/wayland-os.c/wayland-util.c +
// generated protocol glue + libffi closure demarshalling) linked
// unmodified, speaking to our own wlserver.elf over the pathname
// endpoint. Nothing here is stubbed: socket()+connect() through the
// fs view, ppoll() in the dispatch loop, recvmsg MSG_DONTWAIT, real
// SCM_RIGHTS fd passing, fcntl F_DUPFD on the incoming pool fd — the
// same syscalls a linux client makes, answered by the koru seam.
// The session is the canonical one, WITH SEAT + XDG_SHELL: registry
// globals → compositor+shm+seat+xdg_wm_base binds → ping/pong → shm
// formats → surface → get_xdg_surface/get_toplevel + title/app_id →
// EMPTY role commit → toplevel+xsurface configure → ack_configure →
// memfd pool
// (fd crosses ancillary) → buffer → attach/damage/frame/commit →
// callback.done + release → display.sync roundtrip → then a bounded
// dispatch loop collecting wl_pointer enter/motion/button and
// wl_keyboard keymap/key events the compositor routes off its real
// input fd → disconnect (server sees EOS).
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include "wayland-client.h"
#include "wayland-client-protocol.h"
#include "xdg-shell-client-protocol.h"

static int memfd_create(const char *name, unsigned flags) {
    return (int)syscall(319, name, flags);
}

static struct wl_compositor *comp;
static struct wl_shm *shm;
static struct wl_seat *seat;
static struct xdg_wm_base *wmb;
static int fmt_argb, fmt_xrgb;
static struct xdg_toplevel *top;             // declared early — the
                                             // pointer listener moves it
static const struct wl_seat_listener seat_l; // tentative — defined below
static const struct xdg_wm_base_listener wmb_l;

static void reg_global(void *d, struct wl_registry *r, uint32_t name,
                       const char *iface, uint32_t ver) {
    printf("WLR global %u %s v%u\n", name, iface, ver);
    if (strcmp(iface, "wl_compositor") == 0)
        comp = (struct wl_compositor *)wl_registry_bind(r, name,
                 &wl_compositor_interface, ver > 4 ? 4 : ver);
    else if (strcmp(iface, "wl_shm") == 0)
        shm = (struct wl_shm *)wl_registry_bind(r, name,
                &wl_shm_interface, 1);
    else if (strcmp(iface, "wl_seat") == 0) {
        seat = (struct wl_seat *)wl_registry_bind(r, name,
                &wl_seat_interface, ver > 7 ? 7 : ver);
        // capabilities arrive on the SAME roundtrip the bind rode —
        // the listener must be attached inside the callback or the
        // first caps event is dispatched listenerless and dropped.
        wl_seat_add_listener(seat, &seat_l, NULL);
    }
    else if (strcmp(iface, "xdg_wm_base") == 0) {
        wmb = (struct xdg_wm_base *)wl_registry_bind(r, name,
                &xdg_wm_base_interface, 1);
        // ping can land on the same roundtrip as the bind — attach at
        // bind like seat caps or the first ping dies listenerless.
        xdg_wm_base_add_listener(wmb, &wmb_l, NULL);
    }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t name) {}
static const struct wl_registry_listener reg_l = {
    .global = reg_global, .global_remove = reg_remove,
};

static void shm_fmt(void *d, struct wl_shm *s, uint32_t fmt) {
    if (fmt == WL_SHM_FORMAT_ARGB8888) fmt_argb = 1;
    if (fmt == WL_SHM_FORMAT_XRGB8888) fmt_xrgb = 1;
    printf("WLR shm fmt %u\n", fmt);
}
static const struct wl_shm_listener shm_l = { .format = shm_fmt };

static int buf_released;
static void buf_rel(void *d, struct wl_buffer *b) {
    buf_released = 1;
    printf("WLR buffer release\n");
}
static const struct wl_buffer_listener buf_l = { .release = buf_rel };

static int frame_done;
static void cb_done(void *d, struct wl_callback *c, uint32_t data) {
    if (data == 42) { frame_done = 1; printf("WLR frame done=%u\n", data); }
    else printf("WLR sync done=%u\n", data);
}
static const struct wl_callback_listener cb_l = { .done = cb_done };

// ---- seat: the compositor's input fd lands here as protocol ----------
static int got_enter, got_button, got_key;

static void seat_caps(void *d, struct wl_seat *s, uint32_t caps) {
    printf("WLR seat caps %u\n", caps);
}
static void seat_name(void *d, struct wl_seat *s, const char *n) {}
static const struct wl_seat_listener seat_l = {
    .capabilities = seat_caps, .name = seat_name,
};

static void ptr_enter(void *d, struct wl_pointer *p, uint32_t ser,
                      struct wl_surface *s, wl_fixed_t sx, wl_fixed_t sy) {
    got_enter = 1;
    printf("WLR ptr enter s=%u %d,%d\n", ser,
           wl_fixed_to_int(sx), wl_fixed_to_int(sy));
}
static void ptr_leave(void *d, struct wl_pointer *p, uint32_t ser,
                      struct wl_surface *s) {
    printf("WLR ptr leave s=%u\n", ser);
}
static void ptr_motion(void *d, struct wl_pointer *p, uint32_t t,
                       wl_fixed_t sx, wl_fixed_t sy) {
    printf("WLR ptr motion %d,%d\n",
           wl_fixed_to_int(sx), wl_fixed_to_int(sy));
}
static void ptr_button(void *d, struct wl_pointer *p, uint32_t ser,
                       uint32_t t, uint32_t btn, uint32_t st) {
    got_button = 1;
    printf("WLR ptr button %u %u\n", btn, st);
    // the client-initiated drag: a press ON our toplevel is what a
    // real client answers with xdg_toplevel.move(seat, press-serial) —
    // the compositor then owns the grab until release.
    if (st == 1 && top)
        xdg_toplevel_move(top, seat, ser);
}
static void ptr_frame(void *d, struct wl_pointer *p) {}
static const struct wl_pointer_listener ptr_l = {
    .enter = ptr_enter, .leave = ptr_leave,
    .motion = ptr_motion, .button = ptr_button,
    .frame = ptr_frame,   // v5 event a real compositor batches with —
                          // NULL is a protocol error, not a default
};

static void kbd_keymap(void *d, struct wl_keyboard *k, uint32_t fmt,
                       int32_t fd, uint32_t sz) {
    printf("WLR kbd keymap fmt=%u sz=%u\n", fmt, sz);
    close(fd); // protocol delivery proved; parsing is xkbcommon's layer
}
static void kbd_enter(void *d, struct wl_keyboard *k, uint32_t ser,
                      struct wl_surface *s, struct wl_array *keys) {
    printf("WLR kbd enter s=%u\n", ser);
}
static void kbd_leave(void *d, struct wl_keyboard *k, uint32_t ser,
                      struct wl_surface *s) {}
static void kbd_key(void *d, struct wl_keyboard *k, uint32_t ser,
                    uint32_t t, uint32_t key, uint32_t st) {
    got_key = 1;
    printf("WLR kbd key %u %u\n", key, st);
}
static void kbd_mods(void *d, struct wl_keyboard *k, uint32_t ser,
                     uint32_t dep, uint32_t lat, uint32_t lck, uint32_t grp) {}
static void kbd_rep(void *d, struct wl_keyboard *k, int32_t rate,
                    int32_t delay) {}
static const struct wl_keyboard_listener kbd_l = {
    .keymap = kbd_keymap, .enter = kbd_enter, .leave = kbd_leave,
    .key = kbd_key, .modifiers = kbd_mods, .repeat_info = kbd_rep,
};

// ---- xdg_shell: the role contract real clients actually speak ------
// wm_base ping -> pong (liveness), xsurface.configure -> ack + flag;
// a buffer commit before the ack would be a protocol violation the
// compositor names loudly — the ack rides inside the listener so it
// always precedes our attach on the wire.
static uint32_t confser;
static void wmb_ping(void *d, struct xdg_wm_base *b, uint32_t ser) {
    xdg_wm_base_pong(b, ser);
    printf("WLR pong %u\n", ser);
}
static const struct xdg_wm_base_listener wmb_l = { .ping = wmb_ping };

static void xsurf_conf(void *d, struct xdg_surface *s, uint32_t ser) {
    confser = ser;
    xdg_surface_ack_configure(s, ser);
    printf("WLR xsurf conf ser=%u\n", ser);
}
static const struct xdg_surface_listener xsurf_l = {
    .configure = xsurf_conf,
};

static void top_conf(void *d, struct xdg_toplevel *t, int32_t w,
                     int32_t h, struct wl_array *states) {
    printf("WLR toplevel conf %dx%d\n", w, h);
}
static void top_close(void *d, struct xdg_toplevel *t) {}
static const struct xdg_toplevel_listener top_l = {
    .configure = top_conf, .close = top_close,
};

int main(void) {
    setvbuf(stdout, 0, _IONBF, 0); // evidence in real time, not at exit
    // An absolute display name skips XDG_RUNTIME_DIR entirely (the lib
    // requires it absolute anyway): sun_path="/wayland-1" resolves to
    // the same object as "wayland-1" — the walker's empty-component
    // skip makes a leading slash free — the node wlserver bound.
    setenv("WAYLAND_DISPLAY", "/wayland-1", 1);

    // Real libwayland makes ONE connect attempt — retrying until the
    // compositor's socket exists is the caller's job (the server races
    // us to bind+listen; ENOENT/ECONNREFUSED until it's up, same as a
    // desktop client launched beside its compositor).
    struct wl_display *dpy = NULL;
    int tries = 0;
    while (!dpy && tries < 200000) {
        dpy = wl_display_connect(NULL);
        tries++;
    }
    if (!dpy) { printf("WLR FAIL connect e=%d\n", errno); return 1; }
    printf("WLR connected tries=%d\n", tries);

    struct wl_registry *reg = wl_display_get_registry(dpy);
    wl_registry_add_listener(reg, &reg_l, NULL);
    wl_display_roundtrip(dpy);            // globals arrive — ppoll +
                                          // recvmsg inside libwayland
    if (!comp || !shm || !seat || !wmb) {
        printf("WLR FAIL globals c=%p s=%p t=%p x=%p\n",
               (void *)comp, (void *)shm, (void *)seat, (void *)wmb);
        return 1;
    }
    wl_shm_add_listener(shm, &shm_l, NULL);
    wl_display_roundtrip(dpy);            // format events
    if (!fmt_argb || !fmt_xrgb) { printf("WLR FAIL fmt\n"); return 1; }

    // the seat's halves: pointer listener for routed hit events,
    // keyboard for the keymap + focused keys. caps were already heard
    // (the listener attached inside reg_global, at bind time).
    struct wl_pointer *ptr = wl_seat_get_pointer(seat);
    wl_pointer_add_listener(ptr, &ptr_l, NULL);
    struct wl_keyboard *kb = wl_seat_get_keyboard(seat);
    wl_keyboard_add_listener(kb, &kbd_l, NULL);
    wl_display_roundtrip(dpy);            // caps + keymap fd land here

    struct wl_surface *surf = wl_compositor_create_surface(comp);
    // the role: bare wl_surface is NOT how real clients exist — a
    // toplevel must be negotiated before the first buffer lands.
    // get_xdg_surface -> get_toplevel -> metadata -> an EMPTY commit
    // (the role handshake) -> the compositor's configure pair -> ack.
    struct xdg_surface *xsurf = xdg_wm_base_get_xdg_surface(wmb, surf);
    xdg_surface_add_listener(xsurf, &xsurf_l, NULL);
    top = xdg_surface_get_toplevel(xsurf);
    xdg_toplevel_add_listener(top, &top_l, NULL);
    xdg_toplevel_set_title(top, "wlreal");
    xdg_toplevel_set_app_id(top, "wlreal");
    wl_surface_commit(surf);              // role commit — no buffer
    wl_display_roundtrip(dpy);            // toplevel+xsurf configure
    if (!confser) { printf("WLR FAIL no-configure\n"); return 1; }
    // the pool must actually hold the buffer it backs: 64*64*4 ARGB —
    // a short pool is a mapping hole past page 0 (the commit-blit is
    // what first walks the full declared geometry).
    const int poolsize = 64 * 64 * 4;
    int mfd = memfd_create("wlpool", 0);
    if (mfd < 0 || ftruncate(mfd, poolsize) < 0) {
        printf("WLR FAIL memfd e=%d\n", mfd); return 1;
    }
    unsigned char *map = mmap(0, poolsize, PROT_READ | PROT_WRITE,
                              MAP_SHARED, mfd, 0);
    if (map == MAP_FAILED) { printf("WLR FAIL mmap\n"); return 1; }
    map[0] = 0xef; map[1] = 0xbe; map[2] = 0xad; map[3] = 0xde; // deadbeef
    map[4] = 0xee; map[5] = 0xff; map[6] = 0xc0; map[7] = 0x00; // 00c0ffee
    map[256] = 0x5a;

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, mfd, poolsize);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, 64, 64,
                                 256, WL_SHM_FORMAT_ARGB8888);
    wl_buffer_add_listener(buf, &buf_l, NULL);
    wl_shm_pool_destroy(pool);

    wl_surface_attach(surf, buf, 0, 0);
    wl_surface_damage(surf, 0, 0, 64, 64);
    struct wl_callback *cb = wl_surface_frame(surf);
    wl_callback_add_listener(cb, &cb_l, NULL);
    wl_surface_commit(surf);

    struct wl_callback *scb = wl_display_sync(dpy);
    wl_callback_add_listener(scb, &cb_l, NULL);
    wl_display_roundtrip(dpy);            // commit lands: server reads
                                          // our pixels, answers done +
                                          // release + sync done
    if (!frame_done || !buf_released) {
        printf("WLR FAIL framed=%d rel=%d\n", frame_done, buf_released);
        return 1;
    }

    // stay for the input window: the canonical libwayland event loop —
    // prepare_read + poll + read_events/cancel — deadline-bounded so a
    // run with no injected input still exits honestly (the gate's
    // injection rows close the loop earlier once all three routed
    // kinds have landed — waiting for enter AND button AND key keeps
    // event batching deterministic: a fast inject burst can't strand
    // a key behind an early exit. The deadline must outlast the
    // gate's injected sequence even when its sleeps stretch under
    // load — a real client waits forever; this bound only exists so
    // an inputless run still exits.
    int waited = 0;
    while (!(got_enter && got_button && got_key) && waited < 12000) {
        while (wl_display_prepare_read(dpy) != 0)
            wl_display_dispatch_pending(dpy);
        wl_display_flush(dpy);
        struct pollfd pfd = { wl_display_get_fd(dpy), POLLIN, 0 };
        if (poll(&pfd, 1, 200) > 0)
            wl_display_read_events(dpy);
        else
            wl_display_cancel_read(dpy);
        wl_display_dispatch_pending(dpy);
        waited += 200;
    }
    printf("WLR seen enter=%d btn=%d key=%d\n", got_enter, got_button, got_key);
    printf("WLR COMPLETE\n");
    xdg_toplevel_destroy(top);            // role objects die in order —
    xdg_surface_destroy(xsurf);           // toplevel, then xsurface,
    wl_surface_destroy(surf);             // then the bare surface
    wl_display_disconnect(dpy);           // last close → server EOS
    return 0;
}
