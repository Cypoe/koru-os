/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M6: the kms.* driver rows (DESIGN-0001 §0.6, Appendix C.4).
 *
 * This header is the seam between the Linux-ABI DRM personality
 * (drm_linux.c, which owns /dev/dri/card0 and the DRM uAPI) and a scanout
 * provider. The personality never touches device registers; a provider never
 * sees an ioctl. M6 binds the rows to a native koru-os provider
 * (bochs.c, QEMU bochs-display). DS3 is meant to bind the same rows to a
 * driver silo (LKL virtio_gpu); the personality does not change then.
 *
 * Row identities (the names used in logs and in the refusal log):
 *   kms.modes      connector state and mode list           (provider data)
 *   kms.vram       scanout-capable memory, physical range  (provider data)
 *   kms.scanout    show [offset, w x h, pitch] of kms.vram (provider call)
 *   kms.disable    blank the output                        (provider call)
 */
#ifndef KORU_KMS_ROWS_H
#define KORU_KMS_ROWS_H

#include <stdint.h>
#include <stddef.h>

struct kms_mode {
	uint32_t clock; /* kHz */
	uint16_t hdisplay, hsync_start, hsync_end, htotal, hskew;
	uint16_t vdisplay, vsync_start, vsync_end, vtotal, vscan;
	uint32_t vrefresh;
	uint32_t flags; /* DRM_MODE_FLAG_* */
	uint32_t type;  /* DRM_MODE_TYPE_* */
	char name[32];
};

#define KMS_MAX_MODES 8

struct kms_provider {
	const char *name;         /* provider identity, e.g. "bochs-display" */
	int connected;            /* kms.modes */
	uint32_t mm_width, mm_height;
	uint32_t nmodes;
	struct kms_mode modes[KMS_MAX_MODES];
	uint32_t max_width, max_height;
	uint64_t vram_phys;       /* kms.vram */
	uint64_t vram_size;
	void *vram_virt;          /* kernel mapping of kms.vram */
	/* kms.scanout: XRGB8888 only (bpp 32) */
	int (*scanout)(struct kms_provider *p, uint64_t offset, uint32_t w,
		       uint32_t h, uint32_t pitch);
	/* kms.disable */
	int (*disable)(struct kms_provider *p);
};

/* Called by a provider once it is ready. One provider (card0) at first. */
int kms_rows_bind(struct kms_provider *p);

#endif
