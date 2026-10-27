// wlreal.elf — a REAL libwayland client: the vendored libwayland-1.26
// (connection.c/wayland-client.c/wayland-os.c/wayland-util.c +
// generated protocol glue + libffi closure demarshalling) linked
// unmodified, speaking to our own wlserver.elf over the pathname
// endpoint. Nothing here is stubbed: socket()+connect() through the
// fs view, ppoll() in the dispatch loop, recvmsg MSG_DONTWAIT, real
// SCM_RIGHTS fd passing, fcntl F_DUPFD on the incoming pool fd — the
// same syscalls a linux client makes, answered by the koru seam.
// The session is the canonical one: registry globals → compositor+shm
// binds → shm formats → surface → memfd pool (fd crosses ancillary)
// → buffer → attach/damage/frame/commit → callback.done + release →
// display.sync roundtrip → disconnect (server sees EOS).
#include <errno.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include "wayland-client.h"
#include "wayland-client-protocol.h"

static int memfd_create(const char *name, unsigned flags) {
    return (int)syscall(319, name, flags);
}

static struct wl_compositor *comp;
static struct wl_shm *shm;
static int fmt_argb, fmt_xrgb;

static void reg_global(void *d, struct wl_registry *r, uint32_t name,
                       const char *iface, uint32_t ver) {
    printf("WLR global %u %s v%u\n", name, iface, ver);
    if (strcmp(iface, "wl_compositor") == 0)
        comp = (struct wl_compositor *)wl_registry_bind(r, name,
                 &wl_compositor_interface, ver > 4 ? 4 : ver);
    else if (strcmp(iface, "wl_shm") == 0)
        shm = (struct wl_shm *)wl_registry_bind(r, name,
                &wl_shm_interface, 1);
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
    if (data == 43) printf("WLR sync done=%u\n", data);
}
static const struct wl_callback_listener cb_l = { .done = cb_done };

int main(void) {
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
    if (!comp || !shm) { printf("WLR FAIL globals c=%p s=%p\n",
                              (void *)comp, (void *)shm); return 1; }
    wl_shm_add_listener(shm, &shm_l, NULL);
    wl_display_roundtrip(dpy);            // format events
    if (!fmt_argb || !fmt_xrgb) { printf("WLR FAIL fmt\n"); return 1; }

    struct wl_surface *surf = wl_compositor_create_surface(comp);
    int mfd = memfd_create("wlpool", 0);
    if (mfd < 0 || ftruncate(mfd, 4096) < 0) {
        printf("WLR FAIL memfd e=%d\n", mfd); return 1;
    }
    unsigned char *map = mmap(0, 4096, PROT_READ | PROT_WRITE,
                              MAP_SHARED, mfd, 0);
    if (map == MAP_FAILED) { printf("WLR FAIL mmap\n"); return 1; }
    map[0] = 0xef; map[1] = 0xbe; map[2] = 0xad; map[3] = 0xde; // deadbeef
    map[4] = 0xee; map[5] = 0xff; map[6] = 0xc0; map[7] = 0x00; // 00c0ffee
    map[256] = 0x5a;

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, mfd, 4096);
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
    printf("WLR COMPLETE\n");
    wl_display_disconnect(dpy);           // last close → server EOS
    return 0;
}
