/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os: vfscore glue for the ext2 read path (B7).
 *
 * The on-disk logic lives in ext2core.zig (C ABI, allocation-free, host-tested
 * against mke2fs -d images). This file only binds it to Unikraft:
 *   - ukblkdev: submit-and-reap, no queue callback (the same access sequence as
 *     koru-libs unikraft/blk, which documents why uk_blkdev_sync_io is avoided);
 *   - vfscore: mount/lookup/readdir/read/getattr/readlink; everything that would
 *     write returns EROFS. Read-only by construction.
 *
 * fstab device string: the ukblkdev id in decimal ("0").
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <stdio.h>
#include <sys/stat.h>

#include <uk/config.h>
#include <uk/print.h>
#include <uk/assert.h>
#include <uk/alloc.h>
#include <uk/mutex.h>
#include <uk/blkdev.h>
#include <vfscore/mount.h>
#include <vfscore/vnode.h>
#include <vfscore/dentry.h>
#include <vfscore/file.h>
#include <vfscore/uio.h>

#ifndef DT_UNKNOWN
#define DT_UNKNOWN 0
#define DT_FIFO 1
#define DT_CHR 2
#define DT_DIR 4
#define DT_BLK 6
#define DT_REG 8
#define DT_LNK 10
#define DT_SOCK 12
#endif

/* ---- ext2core.zig C ABI (keep in sync with the extern structs there) ---- */
typedef int (*ext2c_read_fn)(void *ctx, uint64_t block, uint8_t *buf);
struct ext2c_fs {
	void *ctx;
	ext2c_read_fn read;
	uint8_t *scratch;
	uint32_t block_size, inodes_count, blocks_count, free_blocks, free_inodes;
	uint32_t first_data_block, blocks_per_group, inodes_per_group, inode_size;
	uint32_t groups, rev, incompat, ro_compat;
};
struct ext2c_inode {
	uint32_t ino;
	uint16_t mode, links, uid, gid;
	uint32_t flags;
	uint64_t size;
	uint32_t atime, ctime, mtime, blocks512, file_acl;
	uint32_t block[15];
};
struct ext2c_dirent {
	uint32_t ino;
	uint8_t file_type, name_len;
	char name[256];
};
int ext2c_probe(struct ext2c_fs *fs, const uint8_t *sb);
int ext2c_read_inode(struct ext2c_fs *fs, uint32_t ino, struct ext2c_inode *out);
int64_t ext2c_read(struct ext2c_fs *fs, const struct ext2c_inode *ip,
		   uint64_t off, uint8_t *buf, uint64_t len);
int ext2c_readdir(struct ext2c_fs *fs, const struct ext2c_inode *dir,
		  uint64_t *pos, struct ext2c_dirent *out);
int ext2c_lookup(struct ext2c_fs *fs, const struct ext2c_inode *dir,
		 const char *name, size_t name_len, uint32_t *out_ino);
int64_t ext2c_readlink(struct ext2c_fs *fs, const struct ext2c_inode *ip,
		       uint8_t *buf, uint64_t cap);

_Static_assert(sizeof(struct ext2c_fs) == 8 + 8 + 8 + 13 * 4 + 4, "ext2c_fs layout");
_Static_assert(sizeof(struct ext2c_inode) == 104, "ext2c_inode layout");

/* ---- block device ---- */
#define KX_QUEUE 0

struct kx_mount {
	struct uk_mutex lock;
	struct uk_blkdev *dev;
	size_t ssize;
	uint8_t *iobuf; /* KX_RA_MAX fs blocks, ioalign-aligned */
	size_t ra_blocks; /* read-ahead run length in fs blocks */
	struct ext2c_fs fs;
	/* Direct-mapped block cache (read-only fs, so never dirty). */
	size_t cache_n;
	uint64_t *cache_tag; /* block number + 1; 0 = empty */
	uint8_t *cache_data;
	uint64_t reads, requests, hits; /* statistics */
};

#define KX_RA_MAX 32
#define KX_CACHE_BYTES (1024 * 1024)

static int kx_transfer(struct kx_mount *km, uint64_t sector, size_t nb, void *buf)
{
	struct uk_blkreq req;
	int status;

	uk_blkreq_init(&req, UK_BLKREQ_READ, sector, nb, buf, NULL, NULL);
	status = uk_blkdev_queue_submit_one(km->dev, KX_QUEUE, &req);
	if (status < 0)
		return -status;
	if (!(status & UK_BLKDEV_STATUS_SUCCESS))
		return EIO;
	while (!uk_blkreq_is_done(&req)) {
		int rc = uk_blkdev_queue_finish_reqs(km->dev, KX_QUEUE);

		if (rc < 0)
			return -rc;
	}
	return req.result < 0 ? EIO : 0;
}

static uint8_t *kx_cache_slot(struct kx_mount *km, uint64_t block)
{
	return km->cache_data + (block % km->cache_n) * km->fs.block_size;
}

/* Block reader handed to ext2core: cache hit, else one request that reads a
 * run of up to ra_blocks consecutive blocks (sequential files and the
 * indirect blocks near them) and fills the cache with all of them.
 */
static int kx_read_block(void *ctx, uint64_t block, uint8_t *buf)
{
	struct kx_mount *km = ctx;
	size_t bs = km->fs.block_size, per = bs / km->ssize, run, i;
	int rc;

	if (km->cache_tag[block % km->cache_n] == block + 1) {
		km->hits++;
		memcpy(buf, kx_cache_slot(km, block), bs);
		return 0;
	}
	run = km->ra_blocks;
	if (block + run > km->fs.blocks_count)
		run = km->fs.blocks_count - block;
	rc = kx_transfer(km, block * per, run * per, km->iobuf);
	if (rc)
		return rc;
	km->requests++;
	km->reads += run;
	for (i = 0; i < run; i++) {
		km->cache_tag[(block + i) % km->cache_n] = block + i + 1;
		memcpy(kx_cache_slot(km, block + i), km->iobuf + i * bs, bs);
	}
	memcpy(buf, km->iobuf, bs);
	return 0;
}

static int kx_dev_open(struct kx_mount *km, unsigned int id)
{
	struct uk_blkdev_conf conf = { .nb_queues = 1 };
	struct uk_blkdev_queue_info qi;
	struct uk_blkdev_queue_conf qc = { 0 };
	const struct uk_blkdev_cap *cap;
	size_t align;
	int rc;

	km->dev = uk_blkdev_get(id);
	if (!km->dev)
		return ENODEV;
	if (uk_blkdev_state_get(km->dev) != UK_BLKDEV_UNCONFIGURED)
		return EBUSY; /* someone else owns it */
	cap = &km->dev->capabilities;
	km->ssize = cap->ssize;
	if (!km->ssize || 4096 % km->ssize)
		return EINVAL;
	rc = uk_blkdev_configure(km->dev, &conf);
	if (rc)
		return -rc;
	rc = uk_blkdev_queue_get_info(km->dev, KX_QUEUE, &qi);
	if (rc)
		goto err_unconf;
	qc.a = uk_alloc_get_default();
	qc.callback = NULL; /* reaped in kx_transfer */
	qc.callback_cookie = NULL;
	rc = uk_blkdev_queue_configure(km->dev, KX_QUEUE, qi.nb_max, &qc);
	if (rc)
		goto err_unconf;
	rc = uk_blkdev_start(km->dev);
	if (rc)
		goto err_unqueue;
	align = cap->ioalign < sizeof(long) ? sizeof(long) : cap->ioalign;
	km->iobuf = memalign(align, KX_RA_MAX * 4096);
	if (!km->iobuf) {
		rc = -ENOMEM;
		goto err_stop;
	}
	return 0;
err_stop:
	uk_blkdev_stop(km->dev);
err_unqueue:
	uk_blkdev_queue_unconfigure(km->dev, KX_QUEUE);
err_unconf:
	uk_blkdev_unconfigure(km->dev);
	return -rc;
}

static void kx_dev_close(struct kx_mount *km)
{
	free(km->iobuf);
	uk_blkdev_stop(km->dev);
	uk_blkdev_queue_unconfigure(km->dev, KX_QUEUE);
	uk_blkdev_unconfigure(km->dev);
}

/* ---- vnode helpers ---- */
#define KX_MOUNT(mp) ((struct kx_mount *)(mp)->m_data)

static enum vtype kx_vtype(uint16_t mode)
{
	switch (mode & S_IFMT) {
	case S_IFDIR: return VDIR;
	case S_IFREG: return VREG;
	case S_IFLNK: return VLNK;
	case S_IFCHR: return VCHR;
	case S_IFBLK: return VBLK;
	case S_IFIFO: return VFIFO;
	case S_IFSOCK: return VSOCK;
	default: return VBAD;
	}
}

static unsigned char kx_dtype(uint16_t mode)
{
	switch (mode & S_IFMT) {
	case S_IFDIR: return DT_DIR;
	case S_IFREG: return DT_REG;
	case S_IFLNK: return DT_LNK;
	case S_IFCHR: return DT_CHR;
	case S_IFBLK: return DT_BLK;
	case S_IFIFO: return DT_FIFO;
	case S_IFSOCK: return DT_SOCK;
	default: return DT_UNKNOWN;
	}
}

static void kx_fill_vnode(struct vnode *vp, const struct ext2c_inode *ip)
{
	vp->v_type = kx_vtype(ip->mode);
	vp->v_mode = ip->mode & 07777;
	vp->v_size = ip->size;
}

/* ---- vfsops ---- */
static struct vnops kx_vnops;

static int kx_mount(struct mount *mp, const char *dev, int flags __unused,
		    const void *data __unused)
{
	struct kx_mount *km;
	struct ext2c_inode *root;
	uint8_t *sb;
	unsigned int id = 0;
	int rc;

	if (dev && *dev) {
		char *end;

		id = (unsigned int)strtoul(dev, &end, 10);
		if (*end)
			return EINVAL;
	}
	km = calloc(1, sizeof(*km));
	if (!km)
		return ENOMEM;
	uk_mutex_init(&km->lock);
	rc = kx_dev_open(km, id);
	if (rc) {
		uk_pr_err("koruext2: blkdev %u: open failed (%d)\n", id, rc);
		free(km);
		return rc;
	}
	/* Superblock: bytes 1024..2047. */
	sb = km->iobuf;
	rc = kx_transfer(km, 1024 / km->ssize, 1024 / km->ssize, sb);
	if (!rc)
		rc = ext2c_probe(&km->fs, sb);
	if (rc) {
		uk_pr_err("koruext2: blkdev %u: not a supported ext2 (%d)\n", id, rc);
		goto err_dev;
	}
	km->fs.ctx = km;
	km->fs.read = kx_read_block;
	km->fs.scratch = malloc(km->fs.block_size);
	km->ra_blocks = KX_RA_MAX;
	if (km->dev->capabilities.max_sectors_per_req &&
	    km->ra_blocks * (km->fs.block_size / km->ssize) >
	    km->dev->capabilities.max_sectors_per_req)
		km->ra_blocks = km->dev->capabilities.max_sectors_per_req /
				(km->fs.block_size / km->ssize);
	if (!km->ra_blocks)
		km->ra_blocks = 1;
	km->cache_n = KX_CACHE_BYTES / km->fs.block_size;
	km->cache_tag = calloc(km->cache_n, sizeof(*km->cache_tag));
	km->cache_data = malloc(KX_CACHE_BYTES);
	root = malloc(sizeof(*root));
	if (!km->fs.scratch || !root || !km->cache_tag || !km->cache_data) {
		free(root);
		rc = ENOMEM;
		goto err_scratch;
	}
	rc = ext2c_read_inode(&km->fs, 2, root);
	if (rc || (root->mode & S_IFMT) != S_IFDIR) {
		free(root);
		rc = rc ? rc : ENOTDIR;
		goto err_scratch;
	}
	mp->m_data = km;
	mp->m_root->d_vnode->v_data = root;
	kx_fill_vnode(mp->m_root->d_vnode, root);
	printf("koruext2: mounted blkdev %u read-only: bs=%u groups=%u blocks=%u free=%u inodes=%u free=%u\n",
		   id, km->fs.block_size, km->fs.groups, km->fs.blocks_count,
		   km->fs.free_blocks, km->fs.inodes_count, km->fs.free_inodes);
	return 0;
err_scratch:
	free(km->fs.scratch);
	free(km->cache_tag);
	free(km->cache_data);
err_dev:
	kx_dev_close(km);
	free(km);
	return rc;
}

static int kx_unmount(struct mount *mp, int flags __unused)
{
	struct kx_mount *km = KX_MOUNT(mp);

	vfscore_release_mp_dentries(mp);
	if (km) {
		printf("koruext2: unmount: %llu blocks in %llu requests, %llu cache hits\n",
			   (unsigned long long)km->reads,
			   (unsigned long long)km->requests,
			   (unsigned long long)km->hits);
		kx_dev_close(km);
		free(km->fs.scratch);
		free(km->cache_tag);
		free(km->cache_data);
		free(km);
	}
	return 0;
}

static int kx_statfs(struct mount *mp, struct statfs *sf)
{
	struct kx_mount *km = KX_MOUNT(mp);

	sf->f_bsize = km->fs.block_size;
	sf->f_blocks = km->fs.blocks_count;
	sf->f_bfree = km->fs.free_blocks;
	sf->f_bavail = km->fs.free_blocks;
	sf->f_files = km->fs.inodes_count;
	sf->f_ffree = km->fs.free_inodes;
	sf->f_namelen = 255;
	return 0;
}

static struct vfsops kx_vfsops = {
	.vfs_mount = kx_mount,
	.vfs_unmount = kx_unmount,
	.vfs_sync = (vfsop_sync_t)vfscore_nullop,
	.vfs_vget = (vfsop_vget_t)vfscore_nullop,
	.vfs_statfs = kx_statfs,
	.vfs_vnops = &kx_vnops,
};

static struct vfscore_fs_type kx_fs_type = {
	.vs_name = "koruext2",
	.vs_init = NULL,
	.vs_op = &kx_vfsops,
};

UK_FS_REGISTER(kx_fs_type);

/* ---- vnops ---- */
static int kx_lookup(struct vnode *dvp, const char *name, struct vnode **vpp)
{
	struct kx_mount *km = KX_MOUNT(dvp->v_mount);
	struct ext2c_inode tmp, *ip;
	struct vnode *vp;
	uint32_t ino;
	int rc;

	*vpp = NULL;
	if (!*name)
		return ENOENT;
	if (strlen(name) > 255)
		return ENAMETOOLONG;
	uk_mutex_lock(&km->lock);
	rc = ext2c_lookup(&km->fs, dvp->v_data, name, strlen(name), &ino);
	if (!rc)
		rc = ext2c_read_inode(&km->fs, ino, &tmp);
	uk_mutex_unlock(&km->lock);
	if (rc)
		return rc;
	if (vfscore_vget(dvp->v_mount, ino, &vp)) {
		*vpp = vp; /* cached; v_data already set */
		return 0;
	}
	if (!vp)
		return ENOMEM;
	ip = malloc(sizeof(*ip));
	if (!ip) {
		vput(vp);
		return ENOMEM;
	}
	*ip = tmp;
	vp->v_data = ip;
	kx_fill_vnode(vp, ip);
	*vpp = vp;
	return 0;
}

static int kx_readdir(struct vnode *vp, struct vfscore_file *fp, struct dirent64 *dir)
{
	struct kx_mount *km = KX_MOUNT(vp->v_mount);
	struct ext2c_dirent ent;
	struct ext2c_inode ip;
	uint64_t pos = (uint64_t)fp->f_offset;
	int r;

	if (vp->v_type != VDIR)
		return ENOTDIR;
	uk_mutex_lock(&km->lock);
	r = ext2c_readdir(&km->fs, vp->v_data, &pos, &ent);
	if (r == 1) {
		/* d_type from the inode: correct with or without FILETYPE. */
		if (ext2c_read_inode(&km->fs, ent.ino, &ip))
			ip.mode = 0;
	}
	uk_mutex_unlock(&km->lock);
	if (r < 0)
		return -r;
	if (r == 0)
		return ENOENT; /* end of directory */
	fp->f_offset = (off_t)pos;
	dir->d_ino = ent.ino;
	dir->d_off = (off_t)pos;
	dir->d_reclen = sizeof(*dir);
	dir->d_type = kx_dtype(ip.mode);
	strlcpy(dir->d_name, ent.name, sizeof(dir->d_name));
	return 0;
}

#define KX_CHUNK (64 * 1024)

static int kx_read(struct vnode *vp, struct vfscore_file *fp __unused,
		   struct uio *uio, int ioflag __unused)
{
	struct kx_mount *km = KX_MOUNT(vp->v_mount);
	const struct ext2c_inode *ip = vp->v_data;
	uint8_t *buf;
	int rc = 0;

	if (vp->v_type == VDIR)
		return EISDIR;
	if (vp->v_type != VREG)
		return EINVAL;
	if (uio->uio_offset < 0)
		return EINVAL;
	if (uio->uio_resid == 0 || (uint64_t)uio->uio_offset >= ip->size)
		return 0;
	buf = malloc(KX_CHUNK);
	if (!buf)
		return ENOMEM;
	while (uio->uio_resid > 0 && (uint64_t)uio->uio_offset < ip->size) {
		size_t want = uio->uio_resid < KX_CHUNK ? uio->uio_resid : KX_CHUNK;
		int64_t n;

		uk_mutex_lock(&km->lock);
		n = ext2c_read(&km->fs, ip, (uint64_t)uio->uio_offset, buf, want);
		uk_mutex_unlock(&km->lock);
		if (n < 0) {
			rc = (int)-n;
			break;
		}
		if (n == 0)
			break;
		rc = vfscore_uiomove(buf, (int)n, uio);
		if (rc)
			break;
	}
	free(buf);
	return rc;
}

static int kx_readlink(struct vnode *vp, struct uio *uio)
{
	struct kx_mount *km = KX_MOUNT(vp->v_mount);
	uint8_t buf[4096];
	int64_t n;

	if (vp->v_type != VLNK)
		return EINVAL;
	if (uio->uio_offset != 0)
		return EINVAL;
	uk_mutex_lock(&km->lock);
	n = ext2c_readlink(&km->fs, vp->v_data, buf, sizeof(buf));
	uk_mutex_unlock(&km->lock);
	if (n < 0)
		return (int)-n;
	if (n > (int64_t)uio->uio_resid)
		n = uio->uio_resid;
	return vfscore_uiomove(buf, (int)n, uio);
}

static int kx_getattr(struct vnode *vp, struct vattr *attr)
{
	const struct ext2c_inode *ip = vp->v_data;
	struct kx_mount *km = KX_MOUNT(vp->v_mount);

	attr->va_type = kx_vtype(ip->mode);
	attr->va_mode = ip->mode & 07777;
	attr->va_nlink = ip->links;
	attr->va_uid = ip->uid;
	attr->va_gid = ip->gid;
	attr->va_nodeid = ip->ino;
	attr->va_atime.tv_sec = ip->atime;
	attr->va_atime.tv_nsec = 0;
	attr->va_mtime.tv_sec = ip->mtime;
	attr->va_mtime.tv_nsec = 0;
	attr->va_ctime.tv_sec = ip->ctime;
	attr->va_ctime.tv_nsec = 0;
	attr->va_rdev = 0;
	attr->va_nblocks = ip->blocks512;
	attr->va_size = ip->size;
	(void)km;
	return 0;
}

static int kx_inactive(struct vnode *vp)
{
	/* The root vnode's data is freed with the mount. */
	if (vp->v_data && vp != vp->v_mount->m_root->d_vnode) {
		free(vp->v_data);
		vp->v_data = NULL;
	}
	return 0;
}

static int kx_erofs() { return EROFS; }

#define kx_open      ((vnop_open_t)vfscore_vop_nullop)
#define kx_close     ((vnop_close_t)vfscore_vop_nullop)
#define kx_seek      ((vnop_seek_t)vfscore_vop_nullop)
#define kx_fsync     ((vnop_fsync_t)vfscore_vop_nullop)
#define kx_ioctl     ((vnop_ioctl_t)vfscore_vop_einval)
#define kx_poll      ((vnop_poll_t)vfscore_vop_einval)

static struct vnops kx_vnops = {
	.vop_open = kx_open,
	.vop_close = kx_close,
	.vop_read = kx_read,
	.vop_write = (vnop_write_t)kx_erofs,
	.vop_seek = kx_seek,
	.vop_ioctl = kx_ioctl,
	.vop_fsync = kx_fsync,
	.vop_readdir = kx_readdir,
	.vop_lookup = kx_lookup,
	.vop_create = (vnop_create_t)kx_erofs,
	.vop_remove = (vnop_remove_t)kx_erofs,
	.vop_rename = (vnop_rename_t)kx_erofs,
	.vop_mkdir = (vnop_mkdir_t)kx_erofs,
	.vop_rmdir = (vnop_rmdir_t)kx_erofs,
	.vop_getattr = kx_getattr,
	.vop_setattr = (vnop_setattr_t)kx_erofs,
	.vop_inactive = kx_inactive,
	.vop_truncate = (vnop_truncate_t)kx_erofs,
	.vop_link = (vnop_link_t)kx_erofs,
	.vop_cache = NULL,
	.vop_fallocate = (vnop_fallocate_t)kx_erofs,
	.vop_readlink = kx_readlink,
	.vop_symlink = (vnop_symlink_t)kx_erofs,
	.vop_poll = kx_poll,
};
