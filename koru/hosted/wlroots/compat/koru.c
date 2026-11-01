// koru-native compat — the arm-truth half of libdrm/libseat.
//
// These aren't stubs that lie: this arm HAS no /dev/dri device nodes
// and no seat manager, so device enumeration failing and session
// creation returning NULL are the honest answers — the same results
// real libdrm gives on hardware without DRM. What changes is WHERE
// the failure lives: not in the compositor's policy but at the arm's
// own edge, named loudly.
//
// drmGetFormatName is different: it's pure fourcc decode, no device —
// we carry the real implementation (mirrors xf86drm.c's verbatim).

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>

// ---- device enumeration: /dev/dri does not exist on this arm -----------

int drmGetDeviceFromDevId(dev_t dev_id, uint32_t flags, drmDevicePtr *device) {
	(void)dev_id; (void)flags; (void)device;
	return -ENODEV;
}

int drmGetDevice2(int fd, uint32_t flags, drmDevicePtr *device) {
	(void)fd; (void)flags; (void)device;
	return -ENODEV;
}

int drmGetDevices2(uint32_t flags, drmDevicePtr devices[], int max_devices) {
	(void)flags; (void)devices; (void)max_devices;
	return -ENODEV;
}

int drmGetDevices(drmDevicePtr devices[], int max_devices) {
	return drmGetDevices2(0, devices, max_devices);
}

void drmFreeDevice(drmDevicePtr *device) {
	(void)device; // never minted — nothing to free
}

void drmFreeDevices(drmDevicePtr devices[], int count) {
	(void)devices; (void)count;
}

// ---- node-fd introspection: only ever called on DRM fds ---------------

int drmGetNodeTypeFromFd(int fd) {
	(void)fd;
	return -ENODEV; // no fd on this arm is a DRM node
}

char *drmGetRenderDeviceNameFromFd(int fd) {
	(void)fd;
	errno = ENODEV;
	return NULL;
}

char *drmGetDeviceNameFromFd2(int fd) {
	(void)fd;
	errno = ENODEV;
	return NULL;
}

char *drmGetDeviceNameFromFd(int fd) {
	(void)fd;
	errno = ENODEV;
	return NULL;
}

// ---- master/auth/lease/prime: device ioctls, all absent ---------------

int drmIsMaster(int fd) {
	(void)fd;
	return 0; // not master — there is no device to be master of
}

int drmGetMagic(int fd, drm_magic_t *magic) {
	(void)fd; (void)magic;
	return -ENODEV;
}

int drmAuthMagic(int fd, drm_magic_t magic) {
	(void)fd; (void)magic;
	return -ENODEV;
}

int drmGetCap(int fd, uint64_t capability, uint64_t *value) {
	(void)fd; (void)capability; (void)value;
	return -ENODEV;
}

int drmIoctl(int fd, unsigned long request, void *arg) {
	(void)fd; (void)request; (void)arg;
	return -ENODEV;
}

int drmPrimeHandleToFD(int fd, uint32_t handle, uint32_t flags, int *prime_fd) {
	(void)fd; (void)handle; (void)flags; (void)prime_fd;
	return -ENODEV;
}

int drmPrimeFDToHandle(int fd, int prime_fd, uint32_t *handle) {
	(void)fd; (void)prime_fd; (void)handle;
	return -ENODEV;
}

int drmModeCreateLease(int fd, const uint32_t *objects, int num_objects,
		int flags, uint32_t *lessee_id) {
	(void)fd; (void)objects; (void)num_objects; (void)flags; (void)lessee_id;
	errno = ENODEV;
	return -1;
}

// ---- pure fourcc decode — the real implementation, verbatim shape -----

char *drmGetFormatName(uint32_t format) {
	char *str, code[5];
	const char *be;
	size_t str_size, i;

	be = (format & DRM_FORMAT_BIG_ENDIAN) ? "_BE" : "";
	format &= ~DRM_FORMAT_BIG_ENDIAN;

	if (format == DRM_FORMAT_INVALID)
		return strdup("INVALID");

	code[0] = (char) ((format >> 0) & 0xFF);
	code[1] = (char) ((format >> 8) & 0xFF);
	code[2] = (char) ((format >> 16) & 0xFF);
	code[3] = (char) ((format >> 24) & 0xFF);
	code[4] = '\0';

	for (i = 3; i > 0 && code[i] == ' '; i--)
		code[i] = '\0';

	str_size = strlen(code) + strlen(be) + 1;
	str = malloc(str_size);
	if (!str)
		return NULL;

	snprintf(str, str_size, "%s%s", code, be);
	return str;
}

// ---- wlr_session: no seat daemon exists on this arm -------------------
// The real answer to "may I have a session" is no — wlroots' autocreate
// only asks on the drm/libinput paths, which never run here. Signatures
// mirror include/wlr/backend/session.h exactly.

#include <wlr/backend/session.h>

struct wlr_session *wlr_session_create(struct wl_display *disp) {
	(void)disp;
	return NULL; // honest: no seatd/logind exists to grant one
}

void wlr_session_destroy(struct wlr_session *session) {
	(void)session;
}

ssize_t wlr_session_find_gpus(struct wlr_session *session,
		size_t ret_len, struct wlr_device **ret) {
	(void)session; (void)ret_len; (void)ret;
	return 0; // zero gpus — the honest scan of an empty /dev/dri
}

struct wlr_device *wlr_session_open_file(struct wlr_session *session,
		const char *path) {
	(void)session; (void)path;
	return NULL;
}

void wlr_session_close_file(struct wlr_session *session,
		struct wlr_device *device) {
	(void)session; (void)device;
}

bool wlr_session_change_vt(struct wlr_session *session, unsigned vt) {
	(void)session; (void)vt;
	return false;
}
