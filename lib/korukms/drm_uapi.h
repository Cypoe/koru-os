/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M6: the subset of the Linux DRM uAPI layout that the personality
 * serves. Struct layouts and ioctl numbers are the Linux ABI (include/uapi/
 * drm/drm.h, drm_mode.h); written out here so the unikernel build does not
 * depend on host kernel headers.
 */
#ifndef KORU_DRM_UAPI_H
#define KORU_DRM_UAPI_H
#include <stdint.h>
#include <stddef.h>

#define DRM_IOCTL_BASE 'd'

struct drm_version {
	int version_major, version_minor, version_patchlevel;
	size_t name_len; char *name;
	size_t date_len; char *date;
	size_t desc_len; char *desc;
};
struct drm_unique { size_t unique_len; char *unique; };
struct drm_set_version { int drm_di_major, drm_di_minor, drm_dd_major, drm_dd_minor; };
struct drm_gem_close { uint32_t handle, pad; };
struct drm_get_cap { uint64_t capability, value; };
struct drm_set_client_cap { uint64_t capability, value; };

struct drm_mode_modeinfo {
	uint32_t clock;
	uint16_t hdisplay, hsync_start, hsync_end, htotal, hskew;
	uint16_t vdisplay, vsync_start, vsync_end, vtotal, vscan;
	uint32_t vrefresh, flags, type;
	char name[32];
};
struct drm_mode_card_res {
	uint64_t fb_id_ptr, crtc_id_ptr, connector_id_ptr, encoder_id_ptr;
	uint32_t count_fbs, count_crtcs, count_connectors, count_encoders;
	uint32_t min_width, max_width, min_height, max_height;
};
struct drm_mode_crtc {
	uint64_t set_connectors_ptr;
	uint32_t count_connectors, crtc_id, fb_id, x, y, gamma_size, mode_valid;
	struct drm_mode_modeinfo mode;
};
struct drm_mode_get_encoder {
	uint32_t encoder_id, encoder_type, crtc_id, possible_crtcs, possible_clones;
};
struct drm_mode_get_connector {
	uint64_t encoders_ptr, modes_ptr, props_ptr, prop_values_ptr;
	uint32_t count_modes, count_props, count_encoders;
	uint32_t encoder_id, connector_id, connector_type, connector_type_id;
	uint32_t connection, mm_width, mm_height, subpixel, pad;
};
struct drm_mode_fb_cmd {
	uint32_t fb_id, width, height, pitch, bpp, depth, handle;
};
struct drm_mode_fb_cmd2 {
	uint32_t fb_id, width, height, pixel_format, flags;
	uint32_t handles[4], pitches[4], offsets[4];
	uint64_t modifier[4];
};
struct drm_mode_fb_dirty_cmd {
	uint32_t fb_id, flags, color, num_clips;
	uint64_t clips_ptr;
};
struct drm_mode_create_dumb {
	uint32_t height, width, bpp, flags, handle, pitch;
	uint64_t size;
};
struct drm_mode_map_dumb { uint32_t handle, pad; uint64_t offset; };
struct drm_mode_destroy_dumb { uint32_t handle; };
struct drm_mode_get_plane_res { uint64_t plane_id_ptr; uint32_t count_planes; };
struct drm_mode_get_plane {
	uint32_t plane_id, crtc_id, fb_id, possible_crtcs, gamma_size;
	uint32_t count_format_types;
	uint64_t format_type_ptr;
};
struct drm_mode_obj_get_properties {
	uint64_t props_ptr, prop_values_ptr;
	uint32_t count_props, obj_id, obj_type;
};

/* ioctl numbers (nr within 'd') */
#define DRM_NR_VERSION            0x00
#define DRM_NR_GET_UNIQUE         0x01
#define DRM_NR_GET_MAGIC          0x02
#define DRM_NR_SET_VERSION        0x07
#define DRM_NR_GEM_CLOSE          0x09
#define DRM_NR_GET_CAP            0x0c
#define DRM_NR_SET_CLIENT_CAP     0x0d
#define DRM_NR_SET_MASTER         0x1e
#define DRM_NR_DROP_MASTER        0x1f
#define DRM_NR_PRIME_HANDLE_TO_FD 0x2d
#define DRM_NR_PRIME_FD_TO_HANDLE 0x2e
#define DRM_NR_MODE_GETRESOURCES  0xa0
#define DRM_NR_MODE_GETCRTC       0xa1
#define DRM_NR_MODE_SETCRTC       0xa2
#define DRM_NR_MODE_CURSOR        0xa3
#define DRM_NR_MODE_GETGAMMA      0xa4
#define DRM_NR_MODE_SETGAMMA      0xa5
#define DRM_NR_MODE_GETENCODER    0xa6
#define DRM_NR_MODE_GETCONNECTOR  0xa7
#define DRM_NR_MODE_GETPROPERTY   0xaa
#define DRM_NR_MODE_SETPROPERTY   0xab
#define DRM_NR_MODE_GETPROPBLOB   0xac
#define DRM_NR_MODE_GETFB         0xad
#define DRM_NR_MODE_ADDFB         0xae
#define DRM_NR_MODE_RMFB          0xaf
#define DRM_NR_MODE_PAGE_FLIP     0xb0
#define DRM_NR_MODE_DIRTYFB       0xb1
#define DRM_NR_MODE_CREATE_DUMB   0xb2
#define DRM_NR_MODE_MAP_DUMB      0xb3
#define DRM_NR_MODE_DESTROY_DUMB  0xb4
#define DRM_NR_MODE_GETPLANERESOURCES 0xb5
#define DRM_NR_MODE_GETPLANE      0xb6
#define DRM_NR_MODE_SETPLANE      0xb7
#define DRM_NR_MODE_ADDFB2        0xb8
#define DRM_NR_MODE_OBJ_GETPROPERTIES 0xb9
#define DRM_NR_MODE_OBJ_SETPROPERTY 0xba
#define DRM_NR_MODE_CURSOR2       0xbb
#define DRM_NR_MODE_ATOMIC        0xbc
#define DRM_NR_MODE_CREATEPROPBLOB 0xbd
#define DRM_NR_MODE_DESTROYPROPBLOB 0xbe

#define DRM_CAP_DUMB_BUFFER          0x1
#define DRM_CAP_VBLANK_HIGH_CRTC     0x2
#define DRM_CAP_DUMB_PREFERRED_DEPTH 0x3
#define DRM_CAP_DUMB_PREFER_SHADOW   0x4
#define DRM_CAP_PRIME                0x5
#define DRM_CAP_TIMESTAMP_MONOTONIC  0x6
#define DRM_CAP_ASYNC_PAGE_FLIP      0x7
#define DRM_CAP_CURSOR_WIDTH         0x8
#define DRM_CAP_CURSOR_HEIGHT        0x9
#define DRM_CAP_ADDFB2_MODIFIERS     0x10
#define DRM_CAP_PAGE_FLIP_TARGET     0x11
#define DRM_CAP_CRTC_IN_VBLANK_EVENT 0x12
#define DRM_CAP_SYNCOBJ              0x13
#define DRM_CAP_SYNCOBJ_TIMELINE     0x14

#define DRM_CLIENT_CAP_STEREO_3D        1
#define DRM_CLIENT_CAP_UNIVERSAL_PLANES 2
#define DRM_CLIENT_CAP_ATOMIC           3
#define DRM_CLIENT_CAP_ASPECT_RATIO     4
#define DRM_CLIENT_CAP_WRITEBACK_CONNECTORS 5

#define DRM_FORMAT_XRGB8888 0x34325258 /* 'XR24' */
#define DRM_MODE_CONNECTOR_VIRTUAL 15
#define DRM_MODE_ENCODER_VIRTUAL   5
#define DRM_MODE_CONNECTED         1
#define DRM_MODE_DISCONNECTED      2
#define DRM_MODE_SUBPIXEL_UNKNOWN  1
#define DRM_MODE_OBJECT_PLANE      0xeeeeeeee
#endif
