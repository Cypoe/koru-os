/* M7b probe: what a libudev client sees (libinput's path backend, and for M9 the
 * compositor's DRM enumeration). Prints, for /dev/input/event0 and /dev/dri/card0
 * (by devnum), the syspath, subsystem, devnode and the sorted properties, the
 * parent chain (subsystem:sysname), and the result of a "drm" and an "input"
 * subsystem enumeration. Lines start with "udevprobe:". */
#include <libudev.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>

static int cmp(const void *a, const void *b) { return strcmp(*(char **)a, *(char **)b); }

static void dump(struct udev *u, const char *node)
{
	struct stat st;
	struct udev_device *d, *p;
	struct udev_list_entry *e;
	char *pr[128]; int n = 0;

	if (stat(node, &st)) { printf("udevprobe: %s: stat failed\n", node); return; }
	d = udev_device_new_from_devnum(u, 'c', st.st_rdev);
	if (!d) { printf("udevprobe: %s: no udev device for %u:%u\n", node, major(st.st_rdev), minor(st.st_rdev)); return; }
	printf("udevprobe: %s syspath=%s subsystem=%s devnode=%s\n", node, udev_device_get_syspath(d),
	       udev_device_get_subsystem(d), udev_device_get_devnode(d) ? udev_device_get_devnode(d) : "(null)");
	udev_list_entry_foreach(e, udev_device_get_properties_list_entry(d)) {
		char *s = malloc(512);
		snprintf(s, 512, "%s=%s", udev_list_entry_get_name(e), udev_list_entry_get_value(e) ? udev_list_entry_get_value(e) : "");
		if (n < 128) pr[n++] = s;
	}
	qsort(pr, n, sizeof(*pr), cmp);
	for (int i = 0; i < n; i++) printf("udevprobe: %s prop %s\n", node, pr[i]);
	for (p = udev_device_get_parent(d); p; p = udev_device_get_parent(p))
		printf("udevprobe: %s parent %s:%s\n", node, udev_device_get_subsystem(p) ? udev_device_get_subsystem(p) : "-",
		       udev_device_get_sysname(p));
	udev_device_unref(d);
}

static void enumerate(struct udev *u, const char *subsys)
{
	struct udev_enumerate *en = udev_enumerate_new(u);
	struct udev_list_entry *e;
	int n = 0;

	udev_enumerate_add_match_subsystem(en, subsys);
	if (udev_enumerate_scan_devices(en) < 0) printf("udevprobe: enumerate %s: scan failed\n", subsys);
	udev_list_entry_foreach(e, udev_enumerate_get_list_entry(en)) {
		struct udev_device *d = udev_device_new_from_syspath(u, udev_list_entry_get_name(e));
		const char *dn = d ? udev_device_get_devnode(d) : NULL;
		printf("udevprobe: enumerate %s: %s devnode=%s\n", subsys, d ? udev_device_get_sysname(d) : "?", dn ? dn : "(null)");
		n++;
		if (d) udev_device_unref(d);
	}
	printf("udevprobe: enumerate %s: %d devices\n", subsys, n);
	udev_enumerate_unref(en);
}

int main(void)
{
	struct udev *u = udev_new();

	if (!u) { printf("udevprobe: udev_new failed\n"); return 1; }
	dump(u, "/dev/input/event0");
	dump(u, "/dev/dri/card0");
	enumerate(u, "drm");
	enumerate(u, "input");
	udev_unref(u);
	printf("udevprobe: DONE\n");
	return 0;
}
