/* SPDX-License-Identifier: BSD-3-Clause */
/* koru-os M7b: minimal Linux sysfs view, see korusysfs.h */
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <uk/print.h>
#include <uk/init.h>
#include "korusysfs.h"

long uk_syscall_r_mount(long, long, long, long, long);
long uk_syscall_r_mkdir(long, long);
long uk_syscall_r_open(long, long, long);
long uk_syscall_r_write(long, long, long);
long uk_syscall_r_close(long);
long uk_syscall_r_symlink(long, long);

#define SYS_MAX_OPS 128
enum { OP_DIR, OP_FILE, OP_LINK };
static struct op { int type; char *a, *b; } ops[SYS_MAX_OPS];
static int nops, mounted, nerr;

static char *dup(const char *s)
{
	size_t n = strlen(s) + 1;
	char *d = malloc(n);

	if (d)
		memcpy(d, s, n);
	return d;
}

static int mkdir_p(const char *rel)
{
	char p[256];
	size_t i, n;
	long rc;

	n = snprintf(p, sizeof(p), "/sys/%s", rel);
	if (n >= sizeof(p))
		return -ENAMETOOLONG;
	for (i = 5; i <= n; i++) {
		if (p[i] != '/' && p[i] != '\0')
			continue;
		p[i] = '\0';
		rc = uk_syscall_r_mkdir((long)p, 0755);
		if (rc < 0 && rc != -EEXIST)
			return (int)rc;
		if (i < n)
			p[i] = '/';
	}
	return 0;
}

static int parent_dir(const char *rel)
{
	char d[256];
	const char *s = strrchr(rel, '/');

	if (!s)
		return 0;
	if ((size_t)(s - rel) >= sizeof(d))
		return -ENAMETOOLONG;
	memcpy(d, rel, s - rel);
	d[s - rel] = '\0';
	return mkdir_p(d);
}

static int do_file(const char *rel, const char *content)
{
	char p[256];
	long fd, rc;
	size_t len = strlen(content);

	if ((rc = parent_dir(rel)))
		return (int)rc;
	snprintf(p, sizeof(p), "/sys/%s", rel);
	fd = uk_syscall_r_open((long)p, O_WRONLY | O_CREAT | O_TRUNC, 0444);
	if (fd < 0)
		return (int)fd;
	rc = uk_syscall_r_write(fd, (long)content, (long)len);
	uk_syscall_r_close(fd);
	return rc < 0 ? (int)rc : ((size_t)rc == len ? 0 : -EIO);
}

/* relative symlink text from the directory of <path> to <target> */
static int do_link(const char *rel, const char *target)
{
	char p[256], t[256];
	const char *a = rel, *b = target, *s;
	size_t o = 0;
	long rc;

	if ((rc = parent_dir(rel)))
		return (int)rc;
	/* strip the common leading directories */
	for (;;) {
		const char *ea = strchr(a, '/'), *eb = strchr(b, '/');

		if (!ea || !eb || ea - a != eb - b || memcmp(a, b, ea - a))
			break;
		a = ea + 1;
		b = eb + 1;
	}
	for (s = a; (s = strchr(s, '/')); s++)
		o += snprintf(t + o, sizeof(t) - o, "../");
	snprintf(t + o, sizeof(t) - o, "%s", b);
	snprintf(p, sizeof(p), "/sys/%s", rel);
	rc = uk_syscall_r_symlink((long)t, (long)p);
	return (rc == -EEXIST) ? 0 : (int)rc;
}

static int apply(int type, const char *a, const char *b)
{
	int rc = type == OP_DIR ? mkdir_p(a)
		 : type == OP_FILE ? do_file(a, b) : do_link(a, b);

	if (rc) {
		nerr++;
		uk_pr_err("koru-os: sysfs: %s /sys/%s failed (%d)\n",
			  type == OP_DIR ? "mkdir" : type == OP_FILE ? "write" : "symlink",
			  a, rc);
	}
	return rc;
}

static int op(int type, const char *a, const char *b)
{
	if (mounted)
		return apply(type, a, b);
	if (nops == SYS_MAX_OPS)
		return -ENOSPC;
	ops[nops].type = type;
	ops[nops].a = dup(a);
	ops[nops].b = b ? dup(b) : NULL;
	if (!ops[nops].a || (b && !ops[nops].b))
		return -ENOMEM;
	nops++;
	return 0;
}

int korusysfs_dir(const char *path) { return op(OP_DIR, path, NULL); }
int korusysfs_file(const char *path, const char *c) { return op(OP_FILE, path, c); }
int korusysfs_link(const char *path, const char *t) { return op(OP_LINK, path, t); }

int korusysfs_device(const char *devpath, const char *subsys,
		     const char *uevent, const char *devnum)
{
	char d[200], p[256], q[256];
	const char *name = strrchr(devpath, '/');
	int rc;

	name = name ? name + 1 : devpath;
	snprintf(d, sizeof(d), "devices/%s", devpath);
	if ((rc = korusysfs_dir(d)))
		return rc;
	snprintf(p, sizeof(p), "%s/uevent", d);
	if ((rc = korusysfs_file(p, uevent)))
		return rc;
	if (subsys) {
		int bus = !strncmp(subsys, "bus/", 4);

		snprintf(p, sizeof(p), bus ? "%s/devices" : "%s", subsys);
		if ((rc = korusysfs_dir(p)))
			return rc;
		snprintf(p, sizeof(p), "%s/subsystem", d);
		if ((rc = korusysfs_link(p, subsys)))
			return rc;
		snprintf(p, sizeof(p), bus ? "%s/devices/%s" : "%s/%s", subsys, name);
		if ((rc = korusysfs_link(p, d)))
			return rc;
	}
	if (devnum) {
		snprintf(p, sizeof(p), "%s/dev", d);
		snprintf(q, sizeof(q), "%s\n", devnum);
		if ((rc = korusysfs_file(p, q)))
			return rc;
		snprintf(p, sizeof(p), "dev/char/%s", devnum);
		if ((rc = korusysfs_link(p, d)))
			return rc;
	}
	return 0;
}

/* After the root and devfs are mounted (rootfs initcalls) and the providers bound. */
static int korusysfs_mount(struct uk_init_ctx *ictx __unused)
{
	long rc;
	int i;

	rc = uk_syscall_r_mount((long)"", (long)"/sys", (long)"ramfs", 0, 0);
	if (rc < 0) {
		uk_pr_err("koru-os: sysfs: mount ramfs on /sys failed (%ld); no /sys view\n", rc);
		return 0;
	}
	mounted = 1;
	apply(OP_DIR, "dev/block", NULL);
	apply(OP_DIR, "dev/char", NULL);
	for (i = 0; i < nops; i++) {
		apply(ops[i].type, ops[i].a, ops[i].b);
		free(ops[i].a);
		free(ops[i].b);
	}
	uk_pr_err("koru-os: INFO sysfs view on /sys: %d entries, %d errors\n", nops, nerr);
	nops = 0;
	return 0;
}
uk_late_initcall(korusysfs_mount, 0x0);
