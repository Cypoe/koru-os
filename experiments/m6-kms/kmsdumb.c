/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M6 test program: legacy-KMS dumb-buffer modeset with raw DRM
 * ioctls (no libdrm), the same calls on L1 (Linux bochs-drm) and on koru-os.
 *
 *   kmsdumb [WxH] [seconds-per-phase]
 *
 * Phase A shows pattern A from dumb buffer A, phase B flips (SETCRTC) to
 * buffer B with pattern B. Each phase prints a marker line, then sleeps so
 * the host can take a screendump. Patterns: see pattern() and expected.py.
 * Last, it probes DRM_CLIENT_CAP_ATOMIC, which koru-os M6 refuses by design.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

#define DIE(...) do { printf("kmsdumb: FAIL " __VA_ARGS__); printf(" (errno %d %s)\n", errno, strerror(errno)); exit(1); } while (0)

static uint32_t pattern(int which, uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{
	static const uint32_t bars[8] = { 0xffffff, 0xffff00, 0x00ffff, 0x00ff00,
					  0xff00ff, 0xff0000, 0x0000ff, 0x000000 };
	uint32_t v;

	if (x == 0 || y == 0 || x == w - 1 || y == h - 1)
		v = 0xffffff;
	else if (y < h / 2)
		v = bars[x * 8 / w];
	else
		v = ((x * 255 / (w - 1)) << 16) | ((y * 255 / (h - 1)) << 8) | ((x ^ y) & 0xff);
	return which ? (~v & 0xffffff) : v;
}

struct buf { uint32_t handle, pitch, fb; uint64_t size; uint32_t *map; };

static void mkbuf(int fd, struct buf *b, uint32_t w, uint32_t h, int which)
{
	struct drm_mode_create_dumb c = { .width = w, .height = h, .bpp = 32 };
	struct drm_mode_map_dumb m = {0};
	struct drm_mode_fb_cmd2 f = {0};

	if (ioctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &c)) DIE("CREATE_DUMB");
	b->handle = c.handle; b->pitch = c.pitch; b->size = c.size;
	m.handle = c.handle;
	if (ioctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &m)) DIE("MAP_DUMB");
	b->map = mmap(NULL, c.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, m.offset);
	if (b->map == MAP_FAILED) DIE("mmap offset 0x%llx", (unsigned long long)m.offset);
	for (uint32_t y = 0; y < h; y++)
		for (uint32_t x = 0; x < w; x++)
			b->map[y * (c.pitch / 4) + x] = pattern(which, x, y, w, h);
	f.width = w; f.height = h; f.pixel_format = 0x34325258; /* XR24 */
	f.handles[0] = c.handle; f.pitches[0] = c.pitch;
	if (ioctl(fd, DRM_IOCTL_MODE_ADDFB2, &f)) DIE("ADDFB2");
	b->fb = f.fb_id;
	printf("kmsdumb: buffer %c handle %u pitch %u size %llu fb %u\n", 'A' + which,
	       c.handle, c.pitch, (unsigned long long)c.size, f.fb_id);
}

int main(int argc, char **argv)
{
	uint32_t W = 1024, H = 768, secs = 3;
	char name[64] = "", date[64] = "", desc[128] = "";
	struct drm_version v = { .name = name, .name_len = 63, .date = date, .date_len = 63,
				 .desc = desc, .desc_len = 127 };
	struct drm_get_cap cap = { .capability = DRM_CAP_DUMB_BUFFER };
	struct drm_mode_card_res r = {0};
	uint32_t crtcs[4], conns[4], encs[4];
	struct drm_mode_get_connector gc = {0};
	struct drm_mode_modeinfo modes[32], *mode = NULL;
	struct drm_mode_crtc sc = {0};
	struct drm_set_client_cap ac = { .capability = DRM_CLIENT_CAP_ATOMIC, .value = 1 };
	struct buf A, B;
	int fd;

	if (argc > 1 && sscanf(argv[1], "%ux%u", &W, &H) != 2) return 2;
	if (argc > 2) secs = atoi(argv[2]);
	setvbuf(stdout, NULL, _IONBF, 0);
	fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (fd < 0) DIE("open /dev/dri/card0");
	if (ioctl(fd, DRM_IOCTL_VERSION, &v)) DIE("VERSION");
	printf("kmsdumb: driver %s %d.%d.%d (%s)\n", name, v.version_major, v.version_minor,
	       v.version_patchlevel, desc);
	if (ioctl(fd, DRM_IOCTL_GET_CAP, &cap) || !cap.value) DIE("no dumb buffers");
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &r)) DIE("GETRESOURCES");
	if (r.count_crtcs < 1 || r.count_connectors < 1 || r.count_crtcs > 4
	    || r.count_connectors > 4 || r.count_encoders > 4) DIE("resources %u/%u/%u", r.count_crtcs, r.count_encoders, r.count_connectors);
	r.crtc_id_ptr = (uintptr_t)crtcs; r.connector_id_ptr = (uintptr_t)conns;
	r.encoder_id_ptr = (uintptr_t)encs; r.count_fbs = 0; r.fb_id_ptr = 0;
	if (ioctl(fd, DRM_IOCTL_MODE_GETRESOURCES, &r)) DIE("GETRESOURCES 2");
	gc.connector_id = conns[0];
	if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &gc)) DIE("GETCONNECTOR");
	if (gc.count_modes > 32) gc.count_modes = 32;
	gc.modes_ptr = (uintptr_t)modes; gc.count_props = 0; gc.count_encoders = 0;
	if (ioctl(fd, DRM_IOCTL_MODE_GETCONNECTOR, &gc)) DIE("GETCONNECTOR 2");
	printf("kmsdumb: crtc %u connector %u type %u connection %u, %u modes:", crtcs[0],
	       conns[0], gc.connector_type, gc.connection, gc.count_modes);
	for (uint32_t i = 0; i < gc.count_modes; i++) {
		printf(" %s", modes[i].name);
		if (!mode && modes[i].hdisplay == W && modes[i].vdisplay == H) mode = &modes[i];
	}
	printf("\n");
	if (!mode) DIE("no mode %ux%u", W, H);
	mkbuf(fd, &A, W, H, 0);
	mkbuf(fd, &B, W, H, 1);
	sc.crtc_id = crtcs[0]; sc.fb_id = A.fb; sc.set_connectors_ptr = (uintptr_t)conns;
	sc.count_connectors = 1; sc.mode_valid = 1; sc.mode = *mode;
	if (ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &sc)) DIE("SETCRTC A");
	printf("kmsdumb: PHASE A scanout %ux%u fb %u\n", W, H, A.fb);
	sleep(secs);
	sc.fb_id = B.fb;
	if (ioctl(fd, DRM_IOCTL_MODE_SETCRTC, &sc)) DIE("SETCRTC B");
	printf("kmsdumb: PHASE B scanout %ux%u fb %u\n", W, H, B.fb);
	sleep(secs);
	{
		int rc = ioctl(fd, DRM_IOCTL_SET_CLIENT_CAP, &ac), e = rc ? errno : 0;

		printf("kmsdumb: probe CLIENT_CAP_ATOMIC -> %d errno %d (%s)\n", rc, e,
		       rc ? strerror(e) : "accepted");
	}
	if (ioctl(fd, DRM_IOCTL_MODE_RMFB, &B.fb)) DIE("RMFB B");
	if (ioctl(fd, DRM_IOCTL_MODE_RMFB, &A.fb)) DIE("RMFB A");
	munmap(A.map, A.size); munmap(B.map, B.size);
	struct drm_mode_destroy_dumb d = { .handle = A.handle };
	if (ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &d)) DIE("DESTROY A");
	d.handle = B.handle;
	if (ioctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &d)) DIE("DESTROY B");
	close(fd);
	printf("kmsdumb: done, exit 0\n");
	return 0;
}
