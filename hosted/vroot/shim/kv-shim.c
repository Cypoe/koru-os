/* kv-shim — minimal parent compositor for the vroot Hyprland oracle.
 *
 * Aquamarine's wayland backend hard-requires five globals:
 *   wl_compositor v6, wl_shm, wl_seat (binds v9), xdg_wm_base v6,
 *   zwp_linux_dmabuf_v1 v4 — the last carries get_default_feedback()
 *   whose main_device dev_t it resolves via drmGetDeviceFromDevId and
 *   opens for its GBM allocator. Weston only advertises dmabuf v3
 *   (feedback landed in v4), and WSLg advertises no dmabuf at all —
 *   so this shim is the v4 parent the environment lacks.
 *
 * It is a real compositor, not a stub: it accepts dmabuf imports, mmaps
 * the BOs for pixel readback, drives frame callbacks, configures the
 * toplevel at $SHIM_W x $SHIM_H, and dumps committed frames as PPM.
 * Hyprland renders its real frames into vgem BOs; the shim is the scanout.
 *
 * Env: SHIM_SOCK (default "kv-shim"), SHIM_DRM_NODE (default
 * /dev/dri/card0 — primary node, first opener is master, dumb-create
 * allowed; the render node fd cannot CREATE_DUMB), SHIM_W/SHIM_H
 * (default 1280x800), SHIM_DUMP (PPM path), SHIM_DUMP_EVERY (commits
 * between dumps, default 30).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>

#include <wayland-server.h>
#include <wayland-server-protocol.h>
#include "xdg-shell-server-protocol.h"
#include "linux-dmabuf-v1-server-protocol.h"

#define LOG(...) do { fprintf(stderr, "SHIM " __VA_ARGS__); fputc('\n', stderr); fflush(stderr); } while (0)

static struct wl_display *dpy;
static dev_t drm_devt;
static const char *dump_path;
static int dump_every = 30;

static uint32_t shm_w = 1280, shm_h = 800;
static uint32_t next_serial;

/* ---------------- buffers ---------------- */

struct kv_buffer {
    struct wl_resource *res;
    bool dmabuf;
    int fds[4];
    uint32_t offset[4], stride[4];
    int nplanes;
    int w, h;
    uint32_t format;          /* DRM fourcc (dmabuf) or wl_shm fmt */
    uint32_t shm_off;         /* shm: byte offset in pool fd */
    int shm_fd;               /* shm: pool fd (dup) */
};

static void buffer_release(struct kv_buffer *b) {
    if (b->res)
        wl_buffer_send_release(b->res);
}

static void buffer_free(struct kv_buffer *b) {
    if (!b) return;
    for (int i = 0; i < b->nplanes; i++) close(b->fds[i]);
    if (b->shm_fd >= 0) close(b->shm_fd);
    free(b);
}

static void buffer_destroy_res(struct wl_resource *res) {
    struct kv_buffer *b = wl_resource_get_user_data(res);
    buffer_release(b);
    buffer_free(b);
}

static void wl_buffer_destroy_req(struct wl_client *cl, struct wl_resource *res) {
    (void)cl;
    buffer_release(wl_resource_get_user_data(res));
    wl_resource_destroy(res);
}

static const struct wl_buffer_interface wl_buffer_impl = {
    .destroy = wl_buffer_destroy_req,
};

static struct wl_resource *buffer_create(struct wl_client *cl, uint32_t id,
                                         int w, int h, uint32_t format) {
    struct kv_buffer *b = calloc(1, sizeof *b);
    b->w = w; b->h = h; b->format = format; b->shm_fd = -1;
    b->res = wl_resource_create(cl, &wl_buffer_interface, 1, id);
    wl_resource_set_implementation(b->res, &wl_buffer_impl, b, buffer_destroy_res);
    return b->res;
}

/* ---------------- surfaces ---------------- */

struct kv_surface {
    struct wl_resource *res;
    struct wl_resource *pending_buf, *cur_buf;
    struct wl_list frame_cbs;      /* kv_framecb links */
    struct wl_resource *xdg_surf, *toplevel;
    char title[128], app_id[64];
    uint64_t commits;
    bool entered;
    /* damage-driven accumulation: a commit's BO only owns the damaged
     * rect — outside it, the surface keeps the previous frame. The shim
     * is the scanout, so it keeps that accumulation itself. */
    bool dmg; int dx, dy, dw, dh;   /* damage union since last commit */
    uint8_t *frame; int fw, fh;     /* accumulated scanout (BGRA) */
    struct wl_list link;
};

static struct wl_list surfaces;   /* kv_surface.link */

static uint32_t now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000u + ts.tv_nsec / 1000000u;
}

/* mmap plane0 of a dmabuf buffer, accumulate the damaged rect into the
 * surface's scanout frame, count non-black px, optional PPM of the
 * ACCUMULATED frame (what a real compositor would show). */
static void readback(struct kv_surface *s, struct kv_buffer *b) {
    if (b->nplanes < 1 || b->fds[0] < 0) return;
    size_t len = (size_t)b->stride[0] * b->h;
    uint8_t *p = mmap(NULL, b->offset[0] + len, PROT_READ, MAP_SHARED,
                      b->fds[0], 0);
    if (p == MAP_FAILED) { LOG("readback: mmap failed: %s", strerror(errno)); return; }
    p += b->offset[0];

    /* damage rect: union recorded by damage/damage_buffer, else full */
    int x0 = s->dmg ? s->dx : 0, y0 = s->dmg ? s->dy : 0;
    int x1 = s->dmg ? s->dx + s->dw : b->w, y1 = s->dmg ? s->dy + s->dh : b->h;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > b->w) x1 = b->w;
    if (y1 > b->h) y1 = b->h;
    s->dmg = false;

    if (!s->frame || s->fw != b->w || s->fh != b->h) {
        s->frame = realloc(s->frame, (size_t)b->w * b->h * 4);
        s->fw = b->w; s->fh = b->h;
        memset(s->frame, 0, (size_t)b->w * b->h * 4);
    }
    uint64_t nonbg = 0;
    for (int y = y0; y < y1; y++) {
        uint8_t *dst = s->frame + (size_t)y * b->w * 4;
        const uint8_t *src = p + (size_t)y * b->stride[0];
        memcpy(dst + (size_t)x0 * 4, src + (size_t)x0 * 4,
               (size_t)(x1 - x0) * 4);
    }
    for (int y = 0; y < b->h; y += 2)
        for (int x = 0; x < b->w; x += 2) {
            const uint8_t *px = s->frame + (size_t)y * b->w * 4 + (size_t)x * 4;
            if (px[0] || px[1] || px[2]) nonbg++;
        }
    LOG("COMMIT buf=%dx%d fmt=%08x commit=%" PRIu64 " nonbg=%" PRIu64 " dmg=%d,%d+%dx%d%s%s%s",
        b->w, b->h, b->format, s->commits, nonbg,
        x0, y0, x1 - x0, y1 - y0,
        s->app_id[0] ? " app=" : "", s->app_id,
        s->title[0] ? " title=" : "");
    if (s->title[0]) fprintf(stderr, "SHIM TITLE %s\n", s->title);
    if (dump_path && s->commits % dump_every == 0) {
        FILE *f = fopen(dump_path, "wb");
        if (f) {
            fprintf(f, "P6\n%d %d\n255\n", b->w, b->h);
            for (int y = 0; y < b->h; y++)
                for (int x = 0; x < b->w; x++) {
                    const uint8_t *px = s->frame + (size_t)y * b->w * 4 + (size_t)x * 4;
                    fputc(px[2], f); fputc(px[1], f); fputc(px[0], f);
                }
            fclose(f);
            LOG("DUMP %s %dx%d", dump_path, b->w, b->h);
        }
    }
    munmap(p - b->offset[0], b->offset[0] + len);
}

static void surface_destroy(struct wl_resource *res) {
    struct kv_surface *s = wl_resource_get_user_data(res);
    wl_list_remove(&s->link);
    free(s->frame);
    free(s);
}

static void sf_destroy(struct wl_client *c, struct wl_resource *r) {
    (void)c; wl_resource_destroy(r);
}
static void sf_attach(struct wl_client *c, struct wl_resource *r,
                    struct wl_resource *buf, int32_t x, int32_t y) {
    (void)c; (void)x; (void)y;
    struct kv_surface *s = wl_resource_get_user_data(r);
    s->pending_buf = buf;
}
static void surf_damage(struct kv_surface *s, int32_t x, int32_t y,
                        int32_t w, int32_t h) {
    if (w <= 0 || h <= 0) return;
    if (!s->dmg) { s->dx = x; s->dy = y; s->dw = w; s->dh = h; s->dmg = true; return; }
    int x1 = s->dx + s->dw, y1 = s->dy + s->dh;
    if (x < s->dx) s->dx = x;
    if (y < s->dy) s->dy = y;
    if (x + w > x1) x1 = x + w;
    if (y + h > y1) y1 = y + h;
    s->dw = x1 - s->dx; s->dh = y1 - s->dy;
}
static void sf_damage(struct wl_client *c, struct wl_resource *r,
                      int32_t a, int32_t b, int32_t d, int32_t e) {
    (void)c; surf_damage(wl_resource_get_user_data(r), a, b, d, e);
}
static void sf_damage_buffer(struct wl_client *c, struct wl_resource *r,
                             int32_t a, int32_t b, int32_t d, int32_t e) {
    (void)c; surf_damage(wl_resource_get_user_data(r), a, b, d, e);
}
/* frame callbacks: resource->link belongs to libwayland (it chains every
 * resource into client->wl_resource_list). Stealing it into our list
 * corrupts the client's resource list — later creates/destroys scribble
 * through dangling links and wl_resource_post_event walks freed memory.
 * Keep our own node per callback. */
struct kv_framecb {
    struct wl_resource *res;
    struct wl_list link;
};

static void framecb_destroy(struct wl_resource *res) {
    struct kv_framecb *f = wl_resource_get_user_data(res);
    wl_list_remove(&f->link);
    free(f);
}

static void sf_frame(struct wl_client *c, struct wl_resource *r,
                     uint32_t cb_id) {
    struct kv_surface *s = wl_resource_get_user_data(r);
    struct kv_framecb *f = calloc(1, sizeof *f);
    f->res = wl_resource_create(c, &wl_callback_interface, 1, cb_id);
    wl_resource_set_implementation(f->res, NULL, f, framecb_destroy);
    wl_list_insert(&s->frame_cbs, &f->link);
    LOG("FRAME-REQ surf=%u cb=%u", wl_resource_get_id(r), cb_id);
}
static void sf_set_opaque(struct wl_client *c, struct wl_resource *r,
                          struct wl_resource *reg) {
    (void)c;(void)r;(void)reg;
}
static void sf_set_input(struct wl_client *c, struct wl_resource *r,
                         struct wl_resource *reg) {
    (void)c;(void)r;(void)reg;
}
static void sf_set_transform(struct wl_client *c, struct wl_resource *r, int32_t t) {
    (void)c;(void)r;(void)t;
}
static void sf_set_scale(struct wl_client *c, struct wl_resource *r, int32_t sc) {
    (void)c;(void)r;(void)sc;
}
static void sf_offset(struct wl_client *c, struct wl_resource *r, int32_t x, int32_t y) {
    (void)c;(void)r;(void)x;(void)y;
}

static struct wl_resource *first_output;

static void sf_commit(struct wl_client *c, struct wl_resource *r) {
    (void)c;
    struct kv_surface *s = wl_resource_get_user_data(r);
    if (s->pending_buf) {
        if (s->cur_buf && s->cur_buf != s->pending_buf)
            buffer_release(wl_resource_get_user_data(s->cur_buf));
        s->cur_buf = s->pending_buf;
        s->pending_buf = NULL;
        s->commits++;
        if (!s->entered && first_output) {
            wl_surface_send_enter(r, first_output);
            s->entered = true;
        }
        struct kv_buffer *b = wl_resource_get_user_data(s->cur_buf);
        if (b && b->dmabuf) readback(s, b);
        /* the shim IS the scanout: the frame is consumed at commit, so the
         * buffer retires immediately. Holding it busy starves aq's
         * swapchain into re-committing a stale BO. */
        buffer_release(wl_resource_get_user_data(s->cur_buf));
        s->cur_buf = NULL;
        /* once the output is live, re-send the configure cycle: aq's first
         * applyConfigure can land before its pendingSize is set, leaving
         * the monitor with a 0x0 pixel size it refuses to repaint. A real
         * compositor reconfigures on mode changes — same wire shape. */
        if (s->xdg_surf && s->commits == 2) {
            struct wl_array states; wl_array_init(&states);
            uint32_t *st = wl_array_add(&states, sizeof(uint32_t));
            *st = XDG_TOPLEVEL_STATE_ACTIVATED;
            xdg_toplevel_send_configure(s->toplevel, shm_w, shm_h, &states);
            wl_array_release(&states);
            xdg_surface_send_configure(s->xdg_surf, ++next_serial);
            LOG("XDG-RECONFIGURE %ux%u serial=%u", shm_w, shm_h, next_serial);
        }
    }
    struct kv_framecb *f, *ft;
    wl_list_for_each_safe(f, ft, &s->frame_cbs, link) {
        uint32_t cbid = wl_resource_get_id(f->res);
        wl_callback_send_done(f->res, now_ms());
        wl_resource_destroy(f->res);
        LOG("FRAME-DONE surf=%u cb=%u", wl_resource_get_id(r), cbid);
    }
}

static const struct wl_surface_interface wl_surface_impl = {
    .destroy = sf_destroy,
    .attach = sf_attach,
    .damage = sf_damage,
    .frame = sf_frame,
    .set_opaque_region = sf_set_opaque,
    .set_input_region = sf_set_input,
    .commit = sf_commit,
    .set_buffer_transform = sf_set_transform,
    .set_buffer_scale = sf_set_scale,
    .damage_buffer = sf_damage_buffer,
    .offset = sf_offset,
};

/* ---------------- region ---------------- */

static void rg_destroy(struct wl_client *c, struct wl_resource *r) { (void)c; wl_resource_destroy(r); }
static void rg_add(struct wl_client *c, struct wl_resource *r, int32_t a, int32_t b, int32_t d, int32_t e) {
    (void)c;(void)r;(void)a;(void)b;(void)d;(void)e;
}
static void rg_subtract(struct wl_client *c, struct wl_resource *r, int32_t a, int32_t b, int32_t d, int32_t e) {
    (void)c;(void)r;(void)a;(void)b;(void)d;(void)e;
}
static const struct wl_region_interface wl_region_impl = {
    .destroy = rg_destroy, .add = rg_add, .subtract = rg_subtract,
};

/* ---------------- compositor ---------------- */

static void comp_create_surface(struct wl_client *cl, struct wl_resource *r, uint32_t id) {
    (void)r;
    struct kv_surface *s = calloc(1, sizeof *s);
    s->res = wl_resource_create(cl, &wl_surface_interface, 6, id);
    wl_list_init(&s->frame_cbs);
    wl_list_insert(&surfaces, &s->link);
    wl_resource_set_implementation(s->res, &wl_surface_impl, s, surface_destroy);
    LOG("SURFACE id=%u", id);
}
static void comp_create_region(struct wl_client *cl, struct wl_resource *r, uint32_t id) {
    (void)r;
    struct wl_resource *reg = wl_resource_create(cl, &wl_region_interface, 1, id);
    wl_resource_set_implementation(reg, &wl_region_impl, NULL, NULL);
}
static const struct wl_compositor_interface wl_compositor_impl = {
    .create_surface = comp_create_surface,
    .create_region = comp_create_region,
};

/* ---------------- shm ---------------- */

static void pool_destroy(struct wl_client *c, struct wl_resource *r) { (void)c; wl_resource_destroy(r); }
static void pool_create_buffer(struct wl_client *cl, struct wl_resource *r,
                               uint32_t id, int32_t off, int32_t w, int32_t h,
                               int32_t stride, uint32_t fmt) {
    (void)stride;
    int *pfd = wl_resource_get_user_data(r);
    struct wl_resource *buf = buffer_create(cl, id, w, h, fmt);
    struct kv_buffer *b = wl_resource_get_user_data(buf);
    b->shm_off = off; b->shm_fd = dup(*pfd); b->stride[0] = stride;
    b->offset[0] = off; b->nplanes = 1;
}
static void pool_resize(struct wl_client *c, struct wl_resource *r, int32_t size) {
    (void)c;(void)r;(void)size;
}
static const struct wl_shm_pool_interface wl_shm_pool_impl = {
    .create_buffer = pool_create_buffer,
    .destroy = pool_destroy,
    .resize = pool_resize,
};

static void shm_create_pool(struct wl_client *cl, struct wl_resource *r,
                            uint32_t id, int fd, int32_t size) {
    (void)r; (void)size;
    int *pfd = malloc(sizeof(int)); *pfd = fd;
    struct wl_resource *pool = wl_resource_create(cl, &wl_shm_pool_interface, 1, id);
    wl_resource_set_implementation(pool, &wl_shm_pool_impl, pfd,
        (void (*)(struct wl_resource *))free);
}
static const struct wl_shm_interface wl_shm_impl = { .create_pool = shm_create_pool };

/* ---------------- seat ---------------- */

static void nop_release(struct wl_client *c, struct wl_resource *r) { (void)c; wl_resource_destroy(r); }

static void ptr_set_cursor(struct wl_client *c, struct wl_resource *r, uint32_t serial,
                           struct wl_resource *surf, int32_t x, int32_t y) {
    (void)c;(void)r;(void)serial;(void)surf;(void)x;(void)y;
}
static const struct wl_pointer_interface wl_pointer_impl = {
    .set_cursor = ptr_set_cursor, .release = nop_release,
};
static const struct wl_keyboard_interface wl_keyboard_impl = { .release = nop_release };
static const struct wl_touch_interface wl_touch_impl = { .release = nop_release };

static void seat_get_pointer(struct wl_client *cl, struct wl_resource *r, uint32_t id) {
    (void)r;
    struct wl_resource *p = wl_resource_create(cl, &wl_pointer_interface,
                                             wl_resource_get_version(r), id);
    wl_resource_set_implementation(p, &wl_pointer_impl, NULL, NULL);
}
static void seat_get_keyboard(struct wl_client *cl, struct wl_resource *r, uint32_t id) {
    (void)r;
    uint32_t ver = wl_resource_get_version(r);
    struct wl_resource *k = wl_resource_create(cl, &wl_keyboard_interface, ver, id);
    wl_resource_set_implementation(k, &wl_keyboard_impl, NULL, NULL);
    int fd = memfd_create("keymap", 0);
    char byte = 0; ssize_t w = write(fd, &byte, 1); (void)w;
    wl_keyboard_send_keymap(k, WL_KEYBOARD_KEYMAP_FORMAT_NO_KEYMAP, fd, 0);
    close(fd);
    if (ver >= 4)
        wl_keyboard_send_repeat_info(k, 25, 600);
}
static void seat_get_touch(struct wl_client *cl, struct wl_resource *r, uint32_t id) {
    (void)r;
    struct wl_resource *t = wl_resource_create(cl, &wl_touch_interface,
                                             wl_resource_get_version(r), id);
    wl_resource_set_implementation(t, &wl_touch_impl, NULL, NULL);
}
static const struct wl_seat_interface wl_seat_impl = {
    .get_pointer = seat_get_pointer,
    .get_keyboard = seat_get_keyboard,
    .get_touch = seat_get_touch,
    .release = nop_release,
};

/* ---------------- output ---------------- */

static const struct wl_output_interface wl_output_impl = { .release = nop_release };

/* ---------------- xdg ---------------- */

static void nop_req(struct wl_client *c, struct wl_resource *r) { (void)c;(void)r; }
static void nop_req_serial(struct wl_client *c, struct wl_resource *r, uint32_t s) {
    (void)c;(void)r;(void)s;
}

static void pos_set_size(struct wl_client *c, struct wl_resource *r, int32_t a, int32_t b) {
    (void)c;(void)r;(void)a;(void)b;
}
static void pos_set_anchor_rect(struct wl_client *c, struct wl_resource *r,
                                int32_t a, int32_t b, int32_t d, int32_t e) {
    (void)c;(void)r;(void)a;(void)b;(void)d;(void)e;
}
static void pos_set_anchor(struct wl_client *c, struct wl_resource *r, uint32_t a) {
    (void)c;(void)r;(void)a;
}
static void pos_set_gravity(struct wl_client *c, struct wl_resource *r, uint32_t a) {
    (void)c;(void)r;(void)a;
}
static void pos_set_adj(struct wl_client *c, struct wl_resource *r, uint32_t a) {
    (void)c;(void)r;(void)a;
}
static void pos_set_offset(struct wl_client *c, struct wl_resource *r, int32_t a, int32_t b) {
    (void)c;(void)r;(void)a;(void)b;
}
static const struct xdg_positioner_interface xdg_positioner_impl = {
    .destroy = nop_req,
    .set_size = pos_set_size,
    .set_anchor_rect = pos_set_anchor_rect,
    .set_anchor = pos_set_anchor,
    .set_gravity = pos_set_gravity,
    .set_constraint_adjustment = pos_set_adj,
    .set_offset = pos_set_offset,
    .set_reactive = nop_req,
    .set_parent_size = pos_set_size,
    .set_parent_configure = nop_req_serial,
};

/* xdg_toplevel */
static void top_set_parent(struct wl_client *c, struct wl_resource *r, struct wl_resource *p) {
    (void)c;(void)r;(void)p;
}
static void top_set_title(struct wl_client *c, struct wl_resource *r, const char *t) {
    (void)c;
    struct kv_surface *s = wl_resource_get_user_data(r);
    snprintf(s->title, sizeof s->title, "%s", t);
    LOG("TOPLEVEL-TITLE %s", t);
}
static void top_set_app_id(struct wl_client *c, struct wl_resource *r, const char *a) {
    (void)c;
    struct kv_surface *s = wl_resource_get_user_data(r);
    snprintf(s->app_id, sizeof s->app_id, "%s", a);
    LOG("TOPLEVEL-APPID %s", a);
}
static void top_menu(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat,
                     uint32_t serial, int32_t x, int32_t y) {
    (void)c;(void)r;(void)seat;(void)serial;(void)x;(void)y;
}
static void top_move(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat,
                     uint32_t serial) {
    (void)c;(void)r;(void)seat;(void)serial;
}
static void top_resize(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat,
                       uint32_t serial, uint32_t edges) {
    (void)c;(void)r;(void)seat;(void)serial;(void)edges;
}
static void top_size(struct wl_client *c, struct wl_resource *r, int32_t w, int32_t h) {
    (void)c;(void)r;(void)w;(void)h;
}
static void top_fullscreen(struct wl_client *c, struct wl_resource *r, struct wl_resource *o) {
    (void)c;(void)r;(void)o;
}
static const struct xdg_toplevel_interface xdg_toplevel_impl = {
    .destroy = nop_req,
    .set_parent = top_set_parent,
    .set_title = top_set_title,
    .set_app_id = top_set_app_id,
    .show_window_menu = top_menu,
    .move = top_move,
    .resize = top_resize,
    .set_max_size = top_size,
    .set_min_size = top_size,
    .set_maximized = nop_req,
    .unset_maximized = nop_req,
    .set_fullscreen = top_fullscreen,
    .unset_fullscreen = nop_req,
    .set_minimized = nop_req,
};

/* xdg_popup */
static void pop_grab(struct wl_client *c, struct wl_resource *r, struct wl_resource *seat,
                     uint32_t serial) {
    (void)c;(void)r;(void)seat;(void)serial;
}
static void pop_reposition(struct wl_client *c, struct wl_resource *r,
                           struct wl_resource *pos, uint32_t tok) {
    (void)c;(void)r;(void)pos;(void)tok;
}
static const struct xdg_popup_interface xdg_popup_impl = {
    .destroy = nop_req, .grab = pop_grab, .reposition = pop_reposition,
};

/* xdg_surface */
static void xs_get_toplevel(struct wl_client *cl, struct wl_resource *r, uint32_t id) {
    struct kv_surface *s = wl_resource_get_user_data(r);
    uint32_t ver = wl_resource_get_version(r);
    struct wl_resource *t = wl_resource_create(cl, &xdg_toplevel_interface, ver, id);
    wl_resource_set_implementation(t, &xdg_toplevel_impl, s, NULL);
    s->toplevel = t;
    struct wl_array states; wl_array_init(&states);
    uint32_t *st = wl_array_add(&states, sizeof(uint32_t));
    *st = XDG_TOPLEVEL_STATE_ACTIVATED;
    xdg_toplevel_send_configure(t, shm_w, shm_h, &states);
    wl_array_release(&states);
    xdg_surface_send_configure(r, ++next_serial);
    LOG("XDG-CONFIGURE %ux%u serial=%u", shm_w, shm_h, next_serial);
}
static void xs_get_popup(struct wl_client *cl, struct wl_resource *r, uint32_t id,
                         struct wl_resource *parent, struct wl_resource *pos) {
    (void)parent; (void)pos;
    uint32_t ver = wl_resource_get_version(r);
    struct wl_resource *p = wl_resource_create(cl, &xdg_popup_interface, ver, id);
    wl_resource_set_implementation(p, &xdg_popup_impl, NULL, NULL);
}
static void xs_set_geometry(struct wl_client *c, struct wl_resource *r,
                            int32_t x, int32_t y, int32_t w, int32_t h) {
    (void)c;(void)r;(void)x;(void)y;(void)w;(void)h;
}
static void xs_ack(struct wl_client *c, struct wl_resource *r, uint32_t serial) {
    (void)c;
    LOG("XDG-ACK %u (expected %u)", serial, next_serial);
}
static const struct xdg_surface_interface xdg_surface_impl = {
    .destroy = nop_req,
    .get_toplevel = xs_get_toplevel,
    .get_popup = xs_get_popup,
    .set_window_geometry = xs_set_geometry,
    .ack_configure = xs_ack,
};

/* xdg_wm_base */
static void wm_create_positioner(struct wl_client *cl, struct wl_resource *r, uint32_t id) {
    uint32_t ver = wl_resource_get_version(r);
    struct wl_resource *p = wl_resource_create(cl, &xdg_positioner_interface, ver, id);
    wl_resource_set_implementation(p, &xdg_positioner_impl, NULL, NULL);
}
static void wm_get_xdg_surface(struct wl_client *cl, struct wl_resource *r,
                               uint32_t id, struct wl_resource *surf) {
    uint32_t ver = wl_resource_get_version(r);
    struct wl_resource *xs = wl_resource_create(cl, &xdg_surface_interface, ver, id);
    struct kv_surface *s = wl_resource_get_user_data(surf);
    s->xdg_surf = xs;
    wl_resource_set_implementation(xs, &xdg_surface_impl, s, NULL);
}
static void wm_pong(struct wl_client *c, struct wl_resource *r, uint32_t serial) {
    (void)c;(void)r;(void)serial;
}
static const struct xdg_wm_base_interface xdg_wm_base_impl = {
    .destroy = nop_req,
    .create_positioner = wm_create_positioner,
    .get_xdg_surface = wm_get_xdg_surface,
    .pong = wm_pong,
};

/* ---------------- linux-dmabuf ---------------- */

struct params_plane { int fd; uint32_t offset, stride; };
struct kv_params {
    struct params_plane planes[4];
    int nplanes;
    bool used;
};

static void params_free(struct wl_resource *res) {
    struct kv_params *p = wl_resource_get_user_data(res);
    for (int i = 0; i < p->nplanes; i++) close(p->planes[i].fd);
    free(p);
}

static void pa_destroy(struct wl_client *c, struct wl_resource *r) { (void)c; wl_resource_destroy(r); }
static void pa_add(struct wl_client *c, struct wl_resource *r, int32_t fd,
                   uint32_t idx, uint32_t off, uint32_t stride,
                   uint32_t mod_hi, uint32_t mod_lo) {
    (void)c;(void)mod_hi;(void)mod_lo;
    struct kv_params *p = wl_resource_get_user_data(r);
    if (idx < 4 && idx == (uint32_t)p->nplanes && p->nplanes < 4) {
        p->planes[idx].fd = fd; p->planes[idx].offset = off; p->planes[idx].stride = stride;
        p->nplanes++;
    } else {
        close(fd);
    }
}

static bool params_finish(struct wl_client *cl, struct wl_resource *r,
                          struct kv_params *p, int32_t w, int32_t h,
                          uint32_t fmt, uint32_t buf_id /* 0 = create() */) {
    if (p->used || p->nplanes < 1 || w <= 0 || h <= 0) {
        if (!buf_id) zwp_linux_buffer_params_v1_send_failed(r);
        return false;
    }
    p->used = true;
    struct wl_resource *buf = buffer_create(cl, buf_id, w, h, fmt);
    struct kv_buffer *b = wl_resource_get_user_data(buf);
    b->dmabuf = true;
    b->nplanes = p->nplanes;
    for (int i = 0; i < p->nplanes; i++) {
        b->fds[i] = p->planes[i].fd; p->planes[i].fd = -1;
        b->offset[i] = p->planes[i].offset;
        b->stride[i] = p->planes[i].stride;
    }
    if (buf_id == 0)
        zwp_linux_buffer_params_v1_send_created(r, buf);
    return true;
}

static void pa_create(struct wl_client *cl, struct wl_resource *r,
                      int32_t w, int32_t h, uint32_t fmt, uint32_t flags) {
    (void)flags;
    params_finish(cl, r, wl_resource_get_user_data(r), w, h, fmt, 0);
}
static void pa_create_immed(struct wl_client *cl, struct wl_resource *r,
                            uint32_t buf_id, int32_t w, int32_t h,
                            uint32_t fmt, uint32_t flags) {
    (void)flags;
    /* create_immed is not a destructor — the params object goes inert but
     * stays alive until the client destroys it; destroying it here makes
     * the client's later `destroy` hit "invalid object". */
    params_finish(cl, r, wl_resource_get_user_data(r), w, h, fmt, buf_id);
}
static const struct zwp_linux_buffer_params_v1_interface params_impl = {
    .destroy = pa_destroy,
    .add = pa_add,
    .create = pa_create,
    .create_immed = pa_create_immed,
};

/* feedback */
struct fmt_entry { uint32_t format, pad; uint64_t modifier; };
static void send_feedback(struct wl_resource *fb) {
    static const struct fmt_entry fmts[] = {
        { 0x34325258, 0, 0 },                 /* XRGB8888 LINEAR */
        { 0x34325241, 0, 0 },                 /* ARGB8888 LINEAR */
        { 0x34325258, 0, 0x00ffffffffffffff },/* XRGB8888 INVALID */
        { 0x34325241, 0, 0x00ffffffffffffff },/* ARGB8888 INVALID */
    };
    int fd = memfd_create("fmts", 0);
    ssize_t w = write(fd, fmts, sizeof fmts); (void)w;
    zwp_linux_dmabuf_feedback_v1_send_format_table(fb, fd, sizeof fmts);
    close(fd);

    struct wl_array dev; wl_array_init(&dev);
    memcpy(wl_array_add(&dev, sizeof drm_devt), &drm_devt, sizeof drm_devt);
    zwp_linux_dmabuf_feedback_v1_send_main_device(fb, &dev);
    zwp_linux_dmabuf_feedback_v1_send_tranche_target_device(fb, &dev);
    wl_array_release(&dev);

    struct wl_array idx; wl_array_init(&idx);
    for (uint16_t i = 0; i < 4; i++)
        memcpy(wl_array_add(&idx, sizeof i), &i, sizeof i);
    zwp_linux_dmabuf_feedback_v1_send_tranche_formats(fb, &idx);
    wl_array_release(&idx);

    zwp_linux_dmabuf_feedback_v1_send_tranche_flags(fb,
        ZWP_LINUX_DMABUF_FEEDBACK_V1_TRANCHE_FLAGS_SCANOUT);
    zwp_linux_dmabuf_feedback_v1_send_tranche_done(fb);
    zwp_linux_dmabuf_feedback_v1_send_done(fb);
    LOG("FEEDBACK dev=%u:%u", major(drm_devt), minor(drm_devt));
}

static void fb_destroy(struct wl_client *c, struct wl_resource *r) { (void)c; wl_resource_destroy(r); }
static const struct zwp_linux_dmabuf_feedback_v1_interface fb_impl = { .destroy = fb_destroy };

static void dmabuf_create_params(struct wl_client *cl, struct wl_resource *r, uint32_t id) {
    struct kv_params *p = calloc(1, sizeof *p);
    struct wl_resource *res = wl_resource_create(cl, &zwp_linux_buffer_params_v1_interface,
                                               wl_resource_get_version(r), id);
    wl_resource_set_implementation(res, &params_impl, p, params_free);
}
static void dmabuf_default_feedback(struct wl_client *cl, struct wl_resource *r, uint32_t id) {
    struct wl_resource *fb = wl_resource_create(cl, &zwp_linux_dmabuf_feedback_v1_interface,
                                               wl_resource_get_version(r), id);
    wl_resource_set_implementation(fb, &fb_impl, NULL, NULL);
    send_feedback(fb);
}
static void dmabuf_surface_feedback(struct wl_client *cl, struct wl_resource *r,
                                    uint32_t id, struct wl_resource *surf) {
    (void)surf;
    dmabuf_default_feedback(cl, r, id);
}
static const struct zwp_linux_dmabuf_v1_interface dmabuf_impl = {
    .destroy = nop_req,
    .create_params = dmabuf_create_params,
    .get_default_feedback = dmabuf_default_feedback,
    .get_surface_feedback = dmabuf_surface_feedback,
};

/* ---------------- global binds ---------------- */

static void bind_shm(struct wl_client *cl, void *d, uint32_t ver, uint32_t id) {
    (void)d;
    struct wl_resource *r = wl_resource_create(cl, &wl_shm_interface, 1, id);
    wl_resource_set_implementation(r, &wl_shm_impl, NULL, NULL);
    wl_shm_send_format(r, WL_SHM_FORMAT_XRGB8888);
    wl_shm_send_format(r, WL_SHM_FORMAT_ARGB8888);
}
static void bind_comp(struct wl_client *cl, void *d, uint32_t ver, uint32_t id) {
    (void)d;
    struct wl_resource *r = wl_resource_create(cl, &wl_compositor_interface,
                                             ver < 6 ? ver : 6, id);
    wl_resource_set_implementation(r, &wl_compositor_impl, NULL, NULL);
}
static void bind_seat(struct wl_client *cl, void *d, uint32_t ver, uint32_t id) {
    (void)d;
    struct wl_resource *r = wl_resource_create(cl, &wl_seat_interface, ver, id);
    wl_resource_set_implementation(r, &wl_seat_impl, NULL, NULL);
    wl_seat_send_capabilities(r, WL_SEAT_CAPABILITY_POINTER | WL_SEAT_CAPABILITY_KEYBOARD);
}
static void bind_output(struct wl_client *cl, void *d, uint32_t ver, uint32_t id) {
    (void)d;
    struct wl_resource *r = wl_resource_create(cl, &wl_output_interface,
                                             ver < 4 ? ver : 4, id);
    LOG("OUTPUT-BIND ver=%u", ver);
    if (!first_output) first_output = r;
    wl_resource_set_implementation(r, &wl_output_impl, NULL, NULL);
    wl_output_send_geometry(r, 0, 0, 340, 270, WL_OUTPUT_SUBPIXEL_NONE,
                            "kv", "kv-shim", WL_OUTPUT_TRANSFORM_NORMAL);
    wl_output_send_mode(r, WL_OUTPUT_MODE_CURRENT | WL_OUTPUT_MODE_PREFERRED,
                        shm_w, shm_h, 60000);
    wl_output_send_scale(r, 1);
    if (ver >= 4) {
        wl_output_send_name(r, "KVSHIM-1");
        wl_output_send_description(r, "koru vroot shim");
    }
    wl_output_send_done(r);
}
static void bind_xdg(struct wl_client *cl, void *d, uint32_t ver, uint32_t id) {
    (void)d;
    LOG("XDG-BIND ver=%u", ver);
    struct wl_resource *r = wl_resource_create(cl, &xdg_wm_base_interface,
                                             ver < 6 ? ver : 6, id);
    wl_resource_set_implementation(r, &xdg_wm_base_impl, NULL, NULL);
}
static void bind_dmabuf(struct wl_client *cl, void *d, uint32_t ver, uint32_t id) {
    (void)d;
    struct wl_resource *r = wl_resource_create(cl, &zwp_linux_dmabuf_v1_interface,
                                             ver < 4 ? ver : 4, id);
    wl_resource_set_implementation(r, &dmabuf_impl, NULL, NULL);
    if (ver < 4) {  /* legacy format events for pre-v4 binds */
        zwp_linux_dmabuf_v1_send_format(r, 0x34325258);
        zwp_linux_dmabuf_v1_send_format(r, 0x34325241);
    }
}

int main(void) {
    wl_list_init(&surfaces);
    const char *sock = getenv("SHIM_SOCK"); if (!sock) sock = "kv-shim";
    const char *node = getenv("SHIM_DRM_NODE"); if (!node) node = "/dev/dri/card0";
    dump_path = getenv("SHIM_DUMP");
    const char *e;
    if ((e = getenv("SHIM_W"))) shm_w = atoi(e);
    if ((e = getenv("SHIM_H"))) shm_h = atoi(e);
    if ((e = getenv("SHIM_DUMP_EVERY"))) dump_every = atoi(e);

    struct stat st;
    if (stat(node, &st) != 0) { LOG("FATAL stat %s: %s", node, strerror(errno)); return 1; }
    drm_devt = st.st_rdev;
    LOG("DRM node %s dev_t=%u:%u", node, major(drm_devt), minor(drm_devt));

    dpy = wl_display_create();
    wl_list_init(&surfaces);
    if (wl_display_add_socket(dpy, sock) != 0) {
        LOG("FATAL add_socket %s: %s", sock, strerror(errno)); return 1;
    }
    LOG("SOCKET %s/%s", getenv("XDG_RUNTIME_DIR") ?: "?", sock);

    wl_global_create(dpy, &wl_compositor_interface, 6, NULL, bind_comp);
    wl_global_create(dpy, &wl_shm_interface, 1, NULL, bind_shm);
    wl_global_create(dpy, &wl_seat_interface, 9, NULL, bind_seat);
    wl_global_create(dpy, &wl_output_interface, 4, NULL, bind_output);
    wl_global_create(dpy, &xdg_wm_base_interface, 6, NULL, bind_xdg);
    wl_global_create(dpy, &zwp_linux_dmabuf_v1_interface, 4, NULL, bind_dmabuf);
    LOG("READY compositor=6 shm=1 seat=9 output=4 xdg=6 dmabuf=4 %ux%u", shm_w, shm_h);

    wl_display_run(dpy);
    return 0;
}
