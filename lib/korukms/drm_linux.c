/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M6: Linux-ABI DRM personality on /dev/dri/card0.
 *
 * Serves the legacy-KMS and dumb-buffer subset of the DRM uAPI on top of the
 * kms.* rows (kms_rows.h). One CRTC, one encoder, one connector, one primary
 * plane; XRGB8888 dumb buffers carved out of the provider's kms.vram.
 * M8b adds legacy page flip with DRM_MODE_PAGE_FLIP_EVENT: the flip takes effect at
 * once (no vblank wait; there is no vblank interrupt on bochs-display) and its
 * DRM_EVENT_FLIP_COMPLETE is read() from the fd, with poll/select/epoll readiness.
 * Every ioctl outside the subset is refused loudly:
 *   koru-os: REFUSED linux.ioctl.<name> (kms)
 * and returns the errno a Linux driver without that feature returns.
 */
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <sys/sysmacros.h>
#include <uk/print.h>
#include <uk/essentials.h>
#include <devfs/device.h>
#include <vfscore/file.h>
#include <vfscore/vnode.h>
#include <vfscore/dentry.h>
#include <vfscore/uio.h>
#include <vfscore/eventpoll.h>
#include <sys/epoll.h>
#include <fcntl.h>
#include <uk/list.h>
#include <uk/wait.h>
#include <uk/plat/time.h>
#include "kms_rows.h"
#include "korusysfs.h"
#include "drm_uapi.h"

#define ID_PLANE     31
#define ID_CRTC      32
#define ID_ENCODER   33
#define ID_CONNECTOR 34
#define FB_ID_BASE   40
#define MAP_BASE     0x10000000ULL /* fake mmap offset space of MAP_DUMB */
#define MAX_BOS 16
#define MAX_FBS 16

struct bo { int used; uint32_t handle; uint64_t off, size; uint32_t w, h, pitch; };
struct fb { int used; uint32_t id, w, h, pitch, handle; uint64_t off; };

static struct {
	struct kms_provider *p;
	struct device *dev;
	struct bo bos[MAX_BOS];
	struct fb fbs[MAX_FBS];
	uint32_t next_handle, next_fb;
	/* CRTC state */
	uint32_t crtc_fb, crtc_x, crtc_y;
	int mode_valid;
	struct drm_mode_modeinfo mode;
	/* M8b: pending DRM events (flip complete), read() by the client */
	struct kms_vblank_event { uint32_t type, length; uint64_t user_data;
		uint32_t tv_sec, tv_usec, sequence, crtc_id; } evq[8];
	unsigned int ev_head, ev_tail;
	uint32_t flip_seq;
	unsigned long flips;
	struct uk_waitq wq;
	struct uk_list_head ecbs;
} K;
_Static_assert(sizeof(((struct kms_vblank_event *)0)[0]) == 32, "drm_event_vblank");
#define DRM_EVENT_FLIP_COMPLETE 0x02
#define DRM_MODE_PAGE_FLIP_EVENT 0x01
struct kms_page_flip { uint32_t crtc_id, fb_id, flags, reserved; uint64_t user_data; };

static const char *drm_nr_name(unsigned nr)
{
	switch (nr) {
#define N(x) case DRM_NR_##x: return "DRM_IOCTL_" #x;
	N(VERSION) N(GET_UNIQUE) N(GET_MAGIC) N(SET_VERSION) N(GEM_CLOSE)
	N(GET_CAP) N(SET_CLIENT_CAP) N(SET_MASTER) N(DROP_MASTER)
	N(PRIME_HANDLE_TO_FD) N(PRIME_FD_TO_HANDLE)
	N(MODE_GETRESOURCES) N(MODE_GETCRTC) N(MODE_SETCRTC) N(MODE_CURSOR)
	N(MODE_GETGAMMA) N(MODE_SETGAMMA) N(MODE_GETENCODER)
	N(MODE_GETCONNECTOR) N(MODE_GETPROPERTY) N(MODE_SETPROPERTY)
	N(MODE_GETPROPBLOB) N(MODE_GETFB) N(MODE_ADDFB) N(MODE_RMFB)
	N(MODE_PAGE_FLIP) N(MODE_DIRTYFB) N(MODE_CREATE_DUMB) N(MODE_MAP_DUMB)
	N(MODE_DESTROY_DUMB) N(MODE_GETPLANERESOURCES) N(MODE_GETPLANE)
	N(MODE_SETPLANE) N(MODE_ADDFB2) N(MODE_OBJ_GETPROPERTIES)
	N(MODE_OBJ_SETPROPERTY) N(MODE_CURSOR2) N(MODE_ATOMIC)
	N(MODE_CREATEPROPBLOB) N(MODE_DESTROYPROPBLOB)
#undef N
	default: return NULL;
	}
}

static int refuse(unsigned long cmd, const char *what, int err)
{
	const char *n = drm_nr_name(cmd & 0xff);

	if (((cmd >> 8) & 0xff) != DRM_IOCTL_BASE)
		uk_pr_err("koru-os: REFUSED linux.ioctl.0x%lx (kms)\n", cmd);
	else if (n)
		uk_pr_err("koru-os: REFUSED linux.ioctl.%s%s%s (kms)\n", n,
			  what ? " " : "", what ? what : "");
	else
		uk_pr_err("koru-os: REFUSED linux.ioctl.DRM_IOCTL_nr_0x%02lx (kms)\n",
			  cmd & 0xff);
	return err;
}

static void put_str(size_t *len, char *dst, const char *s)
{
	size_t n = strlen(s);

	if (dst && *len)
		memcpy(dst, s, n < *len ? n : *len);
	*len = n;
}

static struct bo *bo_get(uint32_t h)
{
	for (int i = 0; i < MAX_BOS; i++)
		if (K.bos[i].used && K.bos[i].handle == h)
			return &K.bos[i];
	return NULL;
}

static struct fb *fb_get(uint32_t id)
{
	for (int i = 0; i < MAX_FBS; i++)
		if (K.fbs[i].used && K.fbs[i].id == id)
			return &K.fbs[i];
	return NULL;
}

/* First fit over kms.vram, page granular. */
static int vram_alloc(uint64_t size, uint64_t *off)
{
	uint64_t cand = 0;
	int moved;

	size = (size + 0xfff) & ~0xfffULL;
	do {
		moved = 0;
		for (int i = 0; i < MAX_BOS; i++) {
			struct bo *b = &K.bos[i];

			if (b->used && cand < b->off + b->size
			    && b->off < cand + size) {
				cand = b->off + b->size;
				moved = 1;
			}
		}
	} while (moved);
	if (cand + size > K.p->vram_size)
		return ENOMEM;
	*off = cand;
	return 0;
}

static void to_modeinfo(const struct kms_mode *m, struct drm_mode_modeinfo *o)
{
	memset(o, 0, sizeof(*o));
	o->clock = m->clock;
	o->hdisplay = m->hdisplay; o->hsync_start = m->hsync_start;
	o->hsync_end = m->hsync_end; o->htotal = m->htotal; o->hskew = m->hskew;
	o->vdisplay = m->vdisplay; o->vsync_start = m->vsync_start;
	o->vsync_end = m->vsync_end; o->vtotal = m->vtotal; o->vscan = m->vscan;
	o->vrefresh = m->vrefresh; o->flags = m->flags; o->type = m->type;
	memcpy(o->name, m->name, sizeof(o->name));
}

static int crtc_disable(void)
{
	K.crtc_fb = 0;
	K.mode_valid = 0;
	memset(&K.mode, 0, sizeof(K.mode));
	return K.p->disable(K.p);
}

static int do_setcrtc(struct drm_mode_crtc *c)
{
	struct fb *f;
	uint32_t fbid = c->fb_id;
	int rc;

	if (c->crtc_id != ID_CRTC)
		return ENOENT;
	if (!c->mode_valid) {
		uk_pr_info("koru-os: kms.disable (SETCRTC without mode)\n");
		return -crtc_disable();
	}
	if (fbid == (uint32_t)-1)
		fbid = K.crtc_fb;
	f = fb_get(fbid);
	if (!f)
		return ENOENT;
	if (c->count_connectors > 1)
		return EINVAL;
	if (c->count_connectors == 1
	    && ((uint32_t *)(uintptr_t)c->set_connectors_ptr)[0] != ID_CONNECTOR)
		return ENOENT;
	if (c->x + c->mode.hdisplay > f->w || c->y + c->mode.vdisplay > f->h)
		return ENOSPC;
	rc = K.p->scanout(K.p, f->off + (uint64_t)c->y * f->pitch + c->x * 4,
			  c->mode.hdisplay, c->mode.vdisplay, f->pitch);
	if (rc)
		return -rc;
	K.crtc_fb = f->id;
	K.crtc_x = c->x;
	K.crtc_y = c->y;
	K.mode = c->mode;
	K.mode_valid = 1;
	return 0;
}

static int add_fb(uint32_t w, uint32_t h, uint32_t pitch, uint32_t handle,
		  uint32_t offset, uint32_t *id)
{
	struct bo *b = bo_get(handle);
	int i;

	if (!b)
		return ENOENT;
	if (!w || !h || pitch < w * 4 || pitch % 4
	    || offset + (uint64_t)pitch * (h - 1) + w * 4 > b->size)
		return EINVAL;
	for (i = 0; i < MAX_FBS && K.fbs[i].used; i++)
		;
	if (i == MAX_FBS)
		return ENOMEM;
	K.fbs[i] = (struct fb){ 1, K.next_fb++, w, h, pitch, handle,
				b->off + offset };
	*id = K.fbs[i].id;
	return 0;
}

static int kms_ioctl(struct device *dev __unused, unsigned long cmd, void *arg)
{
	unsigned nr = cmd & 0xff;

	if (((cmd >> 8) & 0xff) != DRM_IOCTL_BASE)
		return refuse(cmd, NULL, ENOTTY);
	if (!arg && nr != DRM_NR_SET_MASTER && nr != DRM_NR_DROP_MASTER)
		return EFAULT;

	switch (nr) {
	case DRM_NR_VERSION: {
		struct drm_version *v = arg;

		v->version_major = 1;
		v->version_minor = 0;
		v->version_patchlevel = 0;
		put_str(&v->name_len, v->name, "korukms");
		put_str(&v->date_len, v->date, "20261019");
		put_str(&v->desc_len, v->desc,
			"koru-os kms personality (provider bochs-display)");
		return 0;
	}
	case DRM_NR_GET_UNIQUE: {
		struct drm_unique *u = arg;

		u->unique_len = 0; /* no bus id: drmOpenByName accepts it */
		return 0;
	}
	case DRM_NR_SET_VERSION: /* interface 1.4 is all we speak */
		return refuse(cmd, NULL, EINVAL);
	case DRM_NR_SET_MASTER:
	case DRM_NR_DROP_MASTER:
		return 0; /* single client, always master */
	case DRM_NR_GET_CAP: {
		struct drm_get_cap *c = arg;

		switch (c->capability) {
		case DRM_CAP_DUMB_BUFFER: c->value = 1; return 0;
		case DRM_CAP_DUMB_PREFERRED_DEPTH: c->value = 24; return 0;
		case DRM_CAP_DUMB_PREFER_SHADOW: c->value = 0; return 0;
		case DRM_CAP_PRIME: c->value = 0; return 0;
		case DRM_CAP_TIMESTAMP_MONOTONIC: c->value = 1; return 0;
		case DRM_CAP_ADDFB2_MODIFIERS: c->value = 0; return 0;
		case DRM_CAP_VBLANK_HIGH_CRTC:
		case DRM_CAP_ASYNC_PAGE_FLIP:
		case DRM_CAP_PAGE_FLIP_TARGET:
		case DRM_CAP_CRTC_IN_VBLANK_EVENT:
		case DRM_CAP_SYNCOBJ:
		case DRM_CAP_SYNCOBJ_TIMELINE:
			c->value = 0; return 0;
		default: {
			char w[32];

			snprintf(w, sizeof(w), "cap 0x%llx",
				 (unsigned long long)c->capability);
			return refuse(cmd, w, EINVAL);
		}
		}
	}
	case DRM_NR_SET_CLIENT_CAP: {
		struct drm_set_client_cap *c = arg;
		char w[32];

		if (c->capability == DRM_CLIENT_CAP_UNIVERSAL_PLANES
		    || c->capability == DRM_CLIENT_CAP_STEREO_3D)
			return c->value > 1 ? EINVAL : 0;
		snprintf(w, sizeof(w), "cap %llu",
			 (unsigned long long)c->capability);
		/* atomic is not served in M6 (legacy KMS only) */
		return refuse(cmd, w, c->capability == DRM_CLIENT_CAP_ATOMIC
				      ? EOPNOTSUPP : EINVAL);
	}
	case DRM_NR_MODE_GETRESOURCES: {
		struct drm_mode_card_res *r = arg;
		uint32_t nfb = 0;

		for (int i = 0; i < MAX_FBS; i++)
			if (K.fbs[i].used) {
				if (r->fb_id_ptr && r->count_fbs > nfb)
					((uint32_t *)(uintptr_t)r->fb_id_ptr)[nfb]
						= K.fbs[i].id;
				nfb++;
			}
		if (r->crtc_id_ptr && r->count_crtcs >= 1)
			*(uint32_t *)(uintptr_t)r->crtc_id_ptr = ID_CRTC;
		if (r->encoder_id_ptr && r->count_encoders >= 1)
			*(uint32_t *)(uintptr_t)r->encoder_id_ptr = ID_ENCODER;
		if (r->connector_id_ptr && r->count_connectors >= 1)
			*(uint32_t *)(uintptr_t)r->connector_id_ptr = ID_CONNECTOR;
		r->count_fbs = nfb;
		r->count_crtcs = 1;
		r->count_encoders = 1;
		r->count_connectors = 1;
		r->min_width = 1; r->max_width = K.p->max_width;
		r->min_height = 1; r->max_height = K.p->max_height;
		return 0;
	}
	case DRM_NR_MODE_GETCRTC: {
		struct drm_mode_crtc *c = arg;

		if (c->crtc_id != ID_CRTC)
			return ENOENT;
		c->fb_id = K.crtc_fb;
		c->x = K.crtc_x;
		c->y = K.crtc_y;
		c->gamma_size = 0;
		c->mode_valid = K.mode_valid;
		c->mode = K.mode;
		c->count_connectors = 0;
		return 0;
	}
	case DRM_NR_MODE_SETCRTC:
		return do_setcrtc(arg);
	case DRM_NR_MODE_GETENCODER: {
		struct drm_mode_get_encoder *e = arg;

		if (e->encoder_id != ID_ENCODER)
			return ENOENT;
		e->encoder_type = DRM_MODE_ENCODER_VIRTUAL;
		e->crtc_id = K.mode_valid ? ID_CRTC : 0;
		e->possible_crtcs = 1;
		e->possible_clones = 0;
		return 0;
	}
	case DRM_NR_MODE_GETCONNECTOR: {
		struct drm_mode_get_connector *c = arg;
		uint32_t n = K.p->nmodes;

		if (c->connector_id != ID_CONNECTOR)
			return ENOENT;
		if (c->modes_ptr && c->count_modes >= n)
			for (uint32_t i = 0; i < n; i++)
				to_modeinfo(&K.p->modes[i],
					    &((struct drm_mode_modeinfo *)
					      (uintptr_t)c->modes_ptr)[i]);
		if (c->encoders_ptr && c->count_encoders >= 1)
			*(uint32_t *)(uintptr_t)c->encoders_ptr = ID_ENCODER;
		c->count_modes = n;
		c->count_encoders = 1;
		c->count_props = 0;
		c->encoder_id = K.mode_valid ? ID_ENCODER : 0;
		c->connector_type = DRM_MODE_CONNECTOR_VIRTUAL;
		c->connector_type_id = 1;
		c->connection = K.p->connected ? DRM_MODE_CONNECTED
					       : DRM_MODE_DISCONNECTED;
		c->mm_width = K.p->mm_width;
		c->mm_height = K.p->mm_height;
		c->subpixel = DRM_MODE_SUBPIXEL_UNKNOWN;
		return 0;
	}
	case DRM_NR_MODE_OBJ_GETPROPERTIES: {
		struct drm_mode_obj_get_properties *o = arg;

		if (o->obj_id != ID_CRTC && o->obj_id != ID_CONNECTOR
		    && o->obj_id != ID_PLANE && o->obj_id != ID_ENCODER)
			return ENOENT;
		o->count_props = 0; /* no properties until atomic (M9) */
		return 0;
	}
	case DRM_NR_MODE_GETPLANERESOURCES: {
		struct drm_mode_get_plane_res *r = arg;

		if (r->plane_id_ptr && r->count_planes >= 1)
			*(uint32_t *)(uintptr_t)r->plane_id_ptr = ID_PLANE;
		r->count_planes = 1;
		return 0;
	}
	case DRM_NR_MODE_GETPLANE: {
		struct drm_mode_get_plane *p = arg;

		if (p->plane_id != ID_PLANE)
			return ENOENT;
		if (p->format_type_ptr && p->count_format_types >= 1)
			*(uint32_t *)(uintptr_t)p->format_type_ptr
				= DRM_FORMAT_XRGB8888;
		p->count_format_types = 1;
		p->crtc_id = K.mode_valid ? ID_CRTC : 0;
		p->fb_id = K.crtc_fb;
		p->possible_crtcs = 1;
		p->gamma_size = 0;
		return 0;
	}
	case DRM_NR_MODE_CREATE_DUMB: {
		struct drm_mode_create_dumb *d = arg;
		uint64_t off, size;
		int i, rc;

		if (d->bpp != 32 || !d->width || !d->height || d->flags)
			return EINVAL;
		for (i = 0; i < MAX_BOS && K.bos[i].used; i++)
			;
		if (i == MAX_BOS)
			return ENOMEM;
		d->pitch = d->width * 4;
		size = ((uint64_t)d->pitch * d->height + 0xfff) & ~0xfffULL;
		rc = vram_alloc(size, &off);
		if (rc)
			return rc;
		K.bos[i] = (struct bo){ 1, K.next_handle++, off, size,
					d->width, d->height, d->pitch };
		memset((char *)K.p->vram_virt + off, 0, size);
		d->handle = K.bos[i].handle;
		d->size = size;
		return 0;
	}
	case DRM_NR_MODE_MAP_DUMB: {
		struct drm_mode_map_dumb *m = arg;
		struct bo *b = bo_get(m->handle);

		if (!b)
			return ENOENT;
		m->offset = MAP_BASE + b->off;
		return 0;
	}
	case DRM_NR_MODE_DESTROY_DUMB:
	case DRM_NR_GEM_CLOSE: {
		struct bo *b = bo_get(*(uint32_t *)arg);

		if (!b)
			return ENOENT;
		b->used = 0; /* fbs keep their offset; Linux keeps a ref */
		return 0;
	}
	case DRM_NR_MODE_ADDFB: {
		struct drm_mode_fb_cmd *f = arg;

		if (f->bpp != 32 || (f->depth != 24 && f->depth != 32))
			return EINVAL;
		return add_fb(f->width, f->height, f->pitch, f->handle, 0,
			      &f->fb_id);
	}
	case DRM_NR_MODE_ADDFB2: {
		struct drm_mode_fb_cmd2 *f = arg;

		if (f->pixel_format != DRM_FORMAT_XRGB8888 || f->flags
		    || f->handles[1] || f->handles[2] || f->handles[3]) {
			char w[40];

			snprintf(w, sizeof(w), "format 0x%08x flags 0x%x",
				 f->pixel_format, f->flags);
			return refuse(cmd, w, EINVAL);
		}
		return add_fb(f->width, f->height, f->pitches[0], f->handles[0],
			      f->offsets[0], &f->fb_id);
	}
	case DRM_NR_MODE_RMFB: {
		struct fb *f = fb_get(*(uint32_t *)arg);

		if (!f)
			return ENOENT;
		if (K.crtc_fb == f->id) { /* Linux: removing the scanout fb disables the CRTC */
			uk_pr_info("koru-os: kms.disable (RMFB of the scanout fb)\n");
			crtc_disable();
		}
		f->used = 0;
		return 0;
	}
	case DRM_NR_MODE_PAGE_FLIP: {
		struct kms_page_flip *pf = arg;
		struct drm_mode_crtc c;
		struct uk_list_head *it;
		struct fb *f;
		__nsec t;
		int rc;

		if (pf->crtc_id != ID_CRTC)
			return ENOENT;
		if (pf->flags & ~DRM_MODE_PAGE_FLIP_EVENT) {
			char w[24];

			snprintf(w, sizeof(w), "flags 0x%x", pf->flags);
			return refuse(cmd, w, EINVAL);
		}
		if (!K.mode_valid)
			return EINVAL;	/* Linux: CRTC not active */
		f = fb_get(pf->fb_id);
		if (!f)
			return ENOENT;
		if (f->w < K.mode.hdisplay || f->h < K.mode.vdisplay)
			return EINVAL;
		if ((pf->flags & DRM_MODE_PAGE_FLIP_EVENT)
		    && K.ev_head - K.ev_tail >= 8)
			return EBUSY;	/* events not read: like a flip still pending */
		memset(&c, 0, sizeof(c));
		c.crtc_id = ID_CRTC; c.fb_id = f->id; c.x = 0; c.y = 0;
		c.mode = K.mode; c.mode_valid = 1;
		rc = do_setcrtc(&c);
		if (rc)
			return rc;
		K.flips++; K.flip_seq++;
		if (pf->flags & DRM_MODE_PAGE_FLIP_EVENT) {
			struct kms_vblank_event *e = &K.evq[K.ev_head % 8];

			t = ukplat_monotonic_clock();
			*e = (struct kms_vblank_event){ DRM_EVENT_FLIP_COMPLETE,
				sizeof(*e), pf->user_data, t / 1000000000ULL,
				(t % 1000000000ULL) / 1000, K.flip_seq, ID_CRTC };
			K.ev_head++;
			uk_waitq_wake_up(&K.wq);
			uk_list_for_each(it, &K.ecbs)
				eventpoll_signal(uk_list_entry(it, struct eventpoll_cb,
							       cb_link),
						 EPOLLIN | EPOLLRDNORM);
		}
		return 0;
	}
	case DRM_NR_MODE_DIRTYFB: {
		struct drm_mode_fb_dirty_cmd *d = arg;

		/* scanout reads VRAM directly; nothing to flush */
		return fb_get(d->fb_id) ? 0 : ENOENT;
	}
	case DRM_NR_MODE_SETGAMMA:
	case DRM_NR_MODE_GETGAMMA:
		/* gamma_size is 0: direct colour, no LUT */
		return refuse(cmd, NULL, ENOSYS);
	default:
		return refuse(cmd, NULL, EINVAL);
	}
}

static int kms_read(struct device *dev __unused, struct uio *uio, int ioflags)
{
	int rc;

	if (K.ev_head == K.ev_tail) {
		if (ioflags & O_NONBLOCK)
			return EAGAIN;
		uk_waitq_wait_event(&K.wq, K.ev_head != K.ev_tail);
	}
	/* Linux drm_read: whole events only; EINVAL if the first does not fit */
	if (uio->uio_resid < (ssize_t)sizeof(K.evq[0]))
		return EINVAL;
	while (K.ev_head != K.ev_tail
	       && uio->uio_resid >= (ssize_t)sizeof(K.evq[0])) {
		rc = vfscore_uiomove(&K.evq[K.ev_tail % 8], sizeof(K.evq[0]), uio);
		if (rc)
			return rc;
		K.ev_tail++;
	}
	return 0;
}

static void kms_ecb_unregister(struct eventpoll_cb *ecb)
{
	uk_list_del(&ecb->cb_link);
}

static int kms_poll(struct device *dev __unused, unsigned int *revents,
		    struct eventpoll_cb *ecb)
{
	*revents = (K.ev_head != K.ev_tail ? (EPOLLIN | EPOLLRDNORM) : 0)
		   | EPOLLOUT | EPOLLWRNORM;
	if (ecb && !ecb->unregister) {
		ecb->unregister = kms_ecb_unregister;
		uk_list_add_tail(&ecb->cb_link, &K.ecbs);
	}
	return 0;
}

static int kms_open(struct device *dev __unused, int mode __unused)
{
	return 0;
}

static int kms_close(struct device *dev __unused)
{
	K.ev_tail = K.ev_head;	/* Linux drops a closing client's pending events */
	if (K.flips)
		uk_pr_err("koru-os: INFO kms: card0 closed after %lu page flips\n",
			  K.flips);
	return 0;
}

static struct devops kms_devops = {
	.open = kms_open,
	.close = kms_close,
	.read = kms_read,
	.write = (devop_write_t)devop_eperm,
	.ioctl = kms_ioctl,
	.poll = kms_poll,	/* M8b; needs the M7 devfs poll patch */
};

static struct driver kms_drv = {
	.devops = &kms_devops,
	.devsz = 0,
	.name = "korukms",
};

int kms_rows_bind(struct kms_provider *p)
{
	int rc;

	if (K.p)
		return -EBUSY;
	K.p = p;
	K.next_handle = 1;
	K.next_fb = FB_ID_BASE;
	uk_waitq_init(&K.wq);
	UK_INIT_LIST_HEAD(&K.ecbs);
	rc = device_create(&kms_drv, "dri/card0", D_CHR, &K.dev);
	if (rc)
		return -rc;
	K.dev->rdev = makedev(226, 0);
	{	/* M7b sysfs view: <provider device>/drm/card0 */
		char d[160], l[180], t[170];
		const char *par = p->sys_parent ? p->sys_parent : "virtual";

		snprintf(d, sizeof(d), "%s/drm/card0", par);
		korusysfs_device(d, "class/drm", "MAJOR=226\nMINOR=0\n"
				 "DEVNAME=dri/card0\nDEVTYPE=drm_minor\n", "226:0");
		if (p->sys_parent) {
			snprintf(l, sizeof(l), "devices/%s/device", d);
			snprintf(t, sizeof(t), "devices/%s", par);
			korusysfs_link(l, t);
		}
	}
	uk_pr_info("koru-os: kms rows bound: /dev/dri/card0 -> %s\n", p->name);
	return 0;
}

/* posix-mmap hook (patch unikraft-0.21-posix-mmap-device-hook) */
int koruos_dev_mmap(struct vfscore_file *f, off_t offset, size_t len,
		    __paddr_t *paddr)
{
	struct vnode *vp;
	uint64_t o;

	if (!K.p || !f || !f->f_dentry || !(vp = f->f_dentry->d_vnode)
	    || vp->v_data != K.dev)
		return -ENODEV;
	if ((uint64_t)offset < MAP_BASE)
		goto bad;
	o = (uint64_t)offset - MAP_BASE;
	for (int i = 0; i < MAX_BOS; i++) {
		struct bo *b = &K.bos[i];

		if (b->used && o >= b->off && o + len <= b->off + b->size) {
			*paddr = K.p->vram_phys + o;
			return 0;
		}
	}
bad:
	uk_pr_err("koru-os: REFUSED linux.sys.mmap /dev/dri/card0 offset 0x%lx len %lu (no dumb buffer there)\n",
		  (unsigned long)offset, (unsigned long)len);
	return -EINVAL;
}
