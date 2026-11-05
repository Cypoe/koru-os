/* koru-os M6: host check that drm_uapi.h matches the Linux uAPI headers.
 * cc -I.. abi_check.c -o /tmp/abi_check && /tmp/abi_check */
#include <stdio.h>
#include <stddef.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>
#define KORU_NS
#define drm_version k_drm_version
#define drm_unique k_drm_unique
#define drm_set_version k_drm_set_version
#define drm_gem_close k_drm_gem_close
#define drm_get_cap k_drm_get_cap
#define drm_set_client_cap k_drm_set_client_cap
#define drm_mode_modeinfo k_drm_mode_modeinfo
#define drm_mode_card_res k_drm_mode_card_res
#define drm_mode_crtc k_drm_mode_crtc
#define drm_mode_get_encoder k_drm_mode_get_encoder
#define drm_mode_get_connector k_drm_mode_get_connector
#define drm_mode_fb_cmd k_drm_mode_fb_cmd
#define drm_mode_fb_cmd2 k_drm_mode_fb_cmd2
#define drm_mode_fb_dirty_cmd k_drm_mode_fb_dirty_cmd
#define drm_mode_create_dumb k_drm_mode_create_dumb
#define drm_mode_map_dumb k_drm_mode_map_dumb
#define drm_mode_destroy_dumb k_drm_mode_destroy_dumb
#define drm_mode_get_plane_res k_drm_mode_get_plane_res
#define drm_mode_get_plane k_drm_mode_get_plane
#define drm_mode_obj_get_properties k_drm_mode_obj_get_properties
#undef DRM_IOCTL_BASE
#undef DRM_CAP_DUMB_BUFFER
#undef DRM_CAP_VBLANK_HIGH_CRTC
#undef DRM_CAP_DUMB_PREFERRED_DEPTH
#undef DRM_CAP_DUMB_PREFER_SHADOW
#undef DRM_CAP_PRIME
#undef DRM_CAP_TIMESTAMP_MONOTONIC
#undef DRM_CAP_ASYNC_PAGE_FLIP
#undef DRM_CAP_CURSOR_WIDTH
#undef DRM_CAP_CURSOR_HEIGHT
#undef DRM_CAP_ADDFB2_MODIFIERS
#undef DRM_CAP_PAGE_FLIP_TARGET
#undef DRM_CAP_CRTC_IN_VBLANK_EVENT
#undef DRM_CAP_SYNCOBJ
#undef DRM_CAP_SYNCOBJ_TIMELINE
#undef DRM_CLIENT_CAP_STEREO_3D
#undef DRM_CLIENT_CAP_UNIVERSAL_PLANES
#undef DRM_CLIENT_CAP_ATOMIC
#undef DRM_CLIENT_CAP_ASPECT_RATIO
#undef DRM_CLIENT_CAP_WRITEBACK_CONNECTORS
#undef DRM_MODE_CONNECTOR_VIRTUAL
#undef DRM_MODE_ENCODER_VIRTUAL
#undef DRM_MODE_CONNECTED
#undef DRM_MODE_DISCONNECTED
#undef DRM_MODE_SUBPIXEL_UNKNOWN
#undef DRM_MODE_OBJECT_PLANE
#define DRM_FORMAT_XRGB8888_K
#include "drm_uapi.h"
static int bad;
#define S(t, ioc) do { if (sizeof(struct k_##t) != sizeof(struct t) || _IOC_SIZE(ioc) != sizeof(struct k_##t)) { printf("FAIL size %s %zu vs %zu (ioc %u)\n", #t, sizeof(struct k_##t), sizeof(struct t), (unsigned)_IOC_SIZE(ioc)); bad = 1; } else printf("ok   %-28s %3zu B  nr 0x%02x\n", #t, sizeof(struct t), (unsigned)_IOC_NR(ioc)); } while (0)
#define NR(n, ioc) do { if (DRM_NR_##n != _IOC_NR(ioc)) { printf("FAIL nr %s\n", #n); bad = 1; } } while (0)
int main(void)
{
	S(drm_version, DRM_IOCTL_VERSION);
	S(drm_unique, DRM_IOCTL_GET_UNIQUE);
	S(drm_set_version, DRM_IOCTL_SET_VERSION);
	S(drm_gem_close, DRM_IOCTL_GEM_CLOSE);
	S(drm_get_cap, DRM_IOCTL_GET_CAP);
	S(drm_set_client_cap, DRM_IOCTL_SET_CLIENT_CAP);
	S(drm_mode_card_res, DRM_IOCTL_MODE_GETRESOURCES);
	S(drm_mode_crtc, DRM_IOCTL_MODE_GETCRTC);
	S(drm_mode_crtc, DRM_IOCTL_MODE_SETCRTC);
	S(drm_mode_get_encoder, DRM_IOCTL_MODE_GETENCODER);
	S(drm_mode_get_connector, DRM_IOCTL_MODE_GETCONNECTOR);
	S(drm_mode_fb_cmd, DRM_IOCTL_MODE_ADDFB);
	S(drm_mode_fb_cmd2, DRM_IOCTL_MODE_ADDFB2);
	S(drm_mode_fb_dirty_cmd, DRM_IOCTL_MODE_DIRTYFB);
	S(drm_mode_create_dumb, DRM_IOCTL_MODE_CREATE_DUMB);
	S(drm_mode_map_dumb, DRM_IOCTL_MODE_MAP_DUMB);
	S(drm_mode_destroy_dumb, DRM_IOCTL_MODE_DESTROY_DUMB);
	S(drm_mode_get_plane_res, DRM_IOCTL_MODE_GETPLANERESOURCES);
	S(drm_mode_get_plane, DRM_IOCTL_MODE_GETPLANE);
	S(drm_mode_obj_get_properties, DRM_IOCTL_MODE_OBJ_GETPROPERTIES);
	if (sizeof(struct k_drm_mode_modeinfo) != sizeof(struct drm_mode_modeinfo)) { puts("FAIL modeinfo"); bad = 1; }
	NR(VERSION, DRM_IOCTL_VERSION); NR(GET_UNIQUE, DRM_IOCTL_GET_UNIQUE);
	NR(SET_VERSION, DRM_IOCTL_SET_VERSION); NR(GEM_CLOSE, DRM_IOCTL_GEM_CLOSE);
	NR(GET_CAP, DRM_IOCTL_GET_CAP); NR(SET_CLIENT_CAP, DRM_IOCTL_SET_CLIENT_CAP);
	NR(SET_MASTER, DRM_IOCTL_SET_MASTER); NR(DROP_MASTER, DRM_IOCTL_DROP_MASTER);
	NR(PRIME_HANDLE_TO_FD, DRM_IOCTL_PRIME_HANDLE_TO_FD);
	NR(MODE_GETRESOURCES, DRM_IOCTL_MODE_GETRESOURCES); NR(MODE_GETCRTC, DRM_IOCTL_MODE_GETCRTC);
	NR(MODE_SETCRTC, DRM_IOCTL_MODE_SETCRTC); NR(MODE_SETGAMMA, DRM_IOCTL_MODE_SETGAMMA);
	NR(MODE_GETGAMMA, DRM_IOCTL_MODE_GETGAMMA);
	NR(MODE_GETENCODER, DRM_IOCTL_MODE_GETENCODER); NR(MODE_GETCONNECTOR, DRM_IOCTL_MODE_GETCONNECTOR);
	NR(MODE_GETPROPERTY, DRM_IOCTL_MODE_GETPROPERTY); NR(MODE_GETPROPBLOB, DRM_IOCTL_MODE_GETPROPBLOB);
	NR(MODE_ADDFB, DRM_IOCTL_MODE_ADDFB); NR(MODE_RMFB, DRM_IOCTL_MODE_RMFB);
	NR(MODE_PAGE_FLIP, DRM_IOCTL_MODE_PAGE_FLIP); NR(MODE_DIRTYFB, DRM_IOCTL_MODE_DIRTYFB);
	NR(MODE_CREATE_DUMB, DRM_IOCTL_MODE_CREATE_DUMB); NR(MODE_MAP_DUMB, DRM_IOCTL_MODE_MAP_DUMB);
	NR(MODE_DESTROY_DUMB, DRM_IOCTL_MODE_DESTROY_DUMB);
	NR(MODE_GETPLANERESOURCES, DRM_IOCTL_MODE_GETPLANERESOURCES); NR(MODE_GETPLANE, DRM_IOCTL_MODE_GETPLANE);
	NR(MODE_SETPLANE, DRM_IOCTL_MODE_SETPLANE); NR(MODE_ADDFB2, DRM_IOCTL_MODE_ADDFB2);
	NR(MODE_OBJ_GETPROPERTIES, DRM_IOCTL_MODE_OBJ_GETPROPERTIES); NR(MODE_ATOMIC, DRM_IOCTL_MODE_ATOMIC);
	NR(MODE_CREATEPROPBLOB, DRM_IOCTL_MODE_CREATEPROPBLOB); NR(MODE_CURSOR2, DRM_IOCTL_MODE_CURSOR2);
	puts(bad ? "ABI CHECK FAIL" : "ABI CHECK PASS");
	return bad;
}
