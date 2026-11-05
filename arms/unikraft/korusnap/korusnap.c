/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M9: /dev/korusnap — the snapshot path for files on the ramfs /tmp.
 *
 * koruext2 is read-only and /tmp is a ramfs, so a file written there (M9 h3: /tmp/dod3)
 * is gone when the guest stops. Userspace snapshots it explicitly before shutdown by
 * writing a byte stream (here a tar archive made by busybox tar) to /dev/korusnap. On
 * close, the stream is written to block device 1 (a second, scratch virtio-blk disk)
 * as
 *     sector 0:  "KORUSNAP1 <length>\n", zero padded
 *     sector 1+: the stream
 * and the host reads it from that image after QEMU exits. The root image is untouched.
 * One stream per boot; at most KS_MAX bytes; writes beyond it fail with ENOSPC.
 */
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <uk/print.h>
#include <uk/init.h>
#include <uk/alloc.h>
#include <uk/blkdev.h>
#include <devfs/device.h>
#include <vfscore/uio.h>

#define KS_MAX   (1024 * 1024)
#define KS_QUEUE 0

static struct {
	struct device *dev;
	char *buf;
	size_t len;
	int done, opens;
} S;

static int ks_io(struct uk_blkdev *bd, uint64_t sector, size_t nb, void *buf)
{
	struct uk_blkreq req;
	int status;

	uk_blkreq_init(&req, UK_BLKREQ_WRITE, sector, nb, buf, NULL, NULL);
	status = uk_blkdev_queue_submit_one(bd, KS_QUEUE, &req);
	if (status < 0)
		return -status;
	if (!(status & UK_BLKDEV_STATUS_SUCCESS))
		return EIO;
	while (!uk_blkreq_is_done(&req)) {
		int rc = uk_blkdev_queue_finish_reqs(bd, KS_QUEUE);

		if (rc < 0)
			return -rc;
	}
	if (req.result < 0)
		return EIO;
	uk_blkreq_init(&req, UK_BLKREQ_FFLUSH, 0, 0, NULL, NULL, NULL);
	status = uk_blkdev_queue_submit_one(bd, KS_QUEUE, &req);
	if (status >= 0 && (status & UK_BLKDEV_STATUS_SUCCESS))
		while (!uk_blkreq_is_done(&req))
			if (uk_blkdev_queue_finish_reqs(bd, KS_QUEUE) < 0)
				break;
	return 0;
}

static int ks_persist(void)
{
	struct uk_blkdev_conf conf = { .nb_queues = 1 };
	struct uk_blkdev_queue_info qi;
	struct uk_blkdev_queue_conf qc = { 0 };
	struct uk_blkdev *bd = uk_blkdev_get(1);
	size_t ss, align, nsec;
	char *io;
	int rc;

	if (!bd)
		return ENODEV;
	if (uk_blkdev_state_get(bd) != UK_BLKDEV_UNCONFIGURED)
		return EBUSY;
	ss = bd->capabilities.ssize;
	if (!ss || 4096 % ss)
		return EINVAL;
	nsec = 1 + (S.len + ss - 1) / ss;
	if (nsec > bd->capabilities.sectors || (bd->capabilities.mode & O_ACCMODE) == O_RDONLY)
		return ENOSPC;
	if ((rc = uk_blkdev_configure(bd, &conf)))
		return -rc;
	if ((rc = uk_blkdev_queue_get_info(bd, KS_QUEUE, &qi)))
		goto out_unconf;
	qc.a = uk_alloc_get_default();
	if ((rc = uk_blkdev_queue_configure(bd, KS_QUEUE, qi.nb_max, &qc)))
		goto out_unconf;
	if ((rc = uk_blkdev_start(bd)))
		goto out_unqueue;
	align = bd->capabilities.ioalign < sizeof(long) ? sizeof(long)
						     : bd->capabilities.ioalign;
	io = uk_memalign(uk_alloc_get_default(), align, nsec * ss);
	if (!io) {
		rc = -ENOMEM;
	} else {
		memset(io, 0, nsec * ss);
		snprintf(io, ss, "KORUSNAP1 %zu\n", S.len);
		memcpy(io + ss, S.buf, S.len);
		rc = -ks_io(bd, 0, nsec, io);
		uk_free(uk_alloc_get_default(), io);
	}
	uk_blkdev_stop(bd);
out_unqueue:
	uk_blkdev_queue_unconfigure(bd, KS_QUEUE);
out_unconf:
	uk_blkdev_unconfigure(bd);
	return -rc;
}

static int ks_open(struct device *dev __unused, int mode __unused)
{
	if (S.done || S.opens)
		return EBUSY; /* one stream per boot */
	S.opens++;
	return 0;
}

static int ks_write(struct device *dev __unused, struct uio *uio, int ioflags __unused)
{
	size_t n = uio->uio_resid;

	if (S.len + n > KS_MAX)
		return ENOSPC;
	if (!S.buf && !(S.buf = malloc(KS_MAX)))
		return ENOMEM;
	return vfscore_uiomove(S.buf + S.len, n, uio) ? EFAULT : (S.len += n, 0);
}

static int ks_close(struct device *dev __unused)
{
	int rc;

	if (!S.opens)
		return 0;
	S.opens = 0;
	S.done = 1;
	rc = ks_persist();
	if (rc)
		uk_pr_err("koru-os: korusnap: persisting %zu bytes to blkdev 1 failed: %d\n",
			  S.len, rc);
	else
		uk_pr_err("koru-os: INFO korusnap: %zu bytes persisted to blkdev 1\n", S.len);
	free(S.buf);
	S.buf = NULL;
	return rc;
}

static struct devops ks_devops = {
	.open = ks_open,
	.close = ks_close,
	.read = (devop_read_t)devop_eperm,
	.write = ks_write,
	.ioctl = (devop_ioctl_t)devop_eperm,
};

static struct driver ks_drv = {
	.devops = &ks_devops,
	.devsz = 0,
	.name = "korusnap",
};

static int ks_init(struct uk_init_ctx *ictx __unused)
{
	if (uk_blkdev_count() < 2)
		return 0; /* no scratch disk: no snapshot device */
	if (device_create(&ks_drv, "korusnap", D_CHR, &S.dev))
		uk_pr_err("koru-os: korusnap: device_create failed\n");
	return 0;
}
uk_late_initcall(ks_init, 0);
