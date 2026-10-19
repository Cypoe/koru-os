/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M9: memfd_create(2).
 *
 * Wayland shares pixel buffers (wl_shm) and keymaps through memfds passed over
 * SCM_RIGHTS; the compositor and the client each mmap(MAP_SHARED) the same file and must
 * see the same bytes. Unikraft 0.21 has no memfd, and its file mappings are private
 * copies. Here a memfd is an open file of a devfs node /dev/.korumemfd<N> (one per
 * slot); its size is set by ftruncate() (devfs truncate patch: sets the vnode size), its
 * memory is physically contiguous frames allocated at the first mmap/read/write and
 * never resized, and every mmap() of it maps those frames (posix-mmap device hook), so
 * all mappings share them. read()/write()/pread/pwrite go through the kernel's map of them.
 * Not served: growing a file after its memory exists (EFBIG; wl_shm pools that grow
 * re-create the pool), seals (fcntl F_ADD_SEALS/F_GET_SEALS stay EINVAL), hole punching.
 * The frames of a closed memfd are not freed while mappings may exist (no munmap
 * tracking): a leak per closed memfd, bounded by KM_SLOTS slots.
 */
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <uk/print.h>
#include <uk/init.h>
#include <uk/syscall.h>
#include <uk/essentials.h>
#include <uk/paging.h>
#include <uk/falloc.h>
#include <devfs/device.h>
#include <vfscore/file.h>
#include <vfscore/vnode.h>
#include <vfscore/dentry.h>
#include <vfscore/uio.h>

#define KM_SLOTS 256
#define KM_MAXSZ (256UL << 20)

long uk_syscall_r_open(long, long, long);

static struct km {
	struct device *dev;
	struct vnode *vp;
	int opens, used;
	__paddr_t pa;
	__vaddr_t kva;
	size_t size;	/* bytes of memory (page multiple), 0 = none yet */
} M[KM_SLOTS];
static size_t K_total;

static struct km *km_of(struct device *dev)
{
	for (int i = 0; i < KM_SLOTS; i++)
		if (M[i].dev == dev)
			return &M[i];
	return NULL;
}

static int km_alloc(struct km *m, size_t want)
{
	struct uk_pagetable *pt = uk_paging_pt_get_active();
	size_t sz = (want + 0xfff) & ~0xfffUL;
	__paddr_t pa = UK_PAGING_PADDR_ANY;
	__vaddr_t va;
	int rc;

	if (m->size)
		return want <= m->size ? 0 : EFBIG;
	if (!sz || sz > KM_MAXSZ)
		return sz ? EFBIG : EINVAL;
	rc = pt->fa->falloc(pt->fa, &pa, sz >> 12, 0);
	if (rc)
		return ENOMEM;
	va = uk_paging_page_kmap(pt, pa, sz >> 12, 0);
	if (va == UK_PAGING_VADDR_INV) {
		pt->fa->ffree(pt->fa, pa, sz >> 12);
		return ENOMEM;
	}
	memset((void *)va, 0, sz);
	K_total += sz;
	uk_pr_err("koru-os: INFO memfd slot %d: %zu KiB (memfd total %zu KiB)\n",
		  (int)(m - M), sz >> 10, K_total >> 10);
	m->pa = pa;
	m->kva = va;
	m->size = sz;
	return 0;
}

static size_t km_len(struct km *m)
{
	return m->vp ? (size_t)m->vp->v_size : 0;
}

static int km_rw(struct device *dev, struct uio *uio, int write)
{
	struct km *m = km_of(dev);
	size_t len, off = uio->uio_offset;
	int rc;

	if (!m)
		return ENXIO;
	if (write && off + uio->uio_resid > km_len(m)) {
		if (m->size && off + uio->uio_resid > m->size)
			return EFBIG;
		m->vp->v_size = off + uio->uio_resid;
	}
	len = km_len(m);
	if (off >= len)
		return 0;
	if ((rc = km_alloc(m, len)))
		return rc;
	return vfscore_uiomove((char *)m->kva + off,
			       MIN((size_t)uio->uio_resid, len - off), uio);
}
static int km_read(struct device *d, struct uio *u, int f __unused) { return km_rw(d, u, 0); }
static int km_write(struct device *d, struct uio *u, int f __unused) { return km_rw(d, u, 1); }

static int km_open(struct device *dev, int mode __unused)
{
	struct km *m = km_of(dev);

	if (!m || !m->used)
		return ENXIO;
	m->opens++;
	return 0;
}

static int km_close(struct device *dev)
{
	struct km *m = km_of(dev);

	if (m && m->opens && !--m->opens && !m->size) {
		m->used = 0;	/* never had memory: the slot can be reused */
		if (m->vp)
			m->vp->v_size = 0;
		m->vp = NULL;
	}
	return 0;
}

static struct devops km_ops = {
	.open = km_open, .close = km_close, .read = km_read, .write = km_write,
	.ioctl = (devop_ioctl_t)devop_eperm,
};
static struct driver km_drv = { .devops = &km_ops, .devsz = 0, .name = "korumemfd" };

/* called by the posix-mmap device hook (lib/korukms koruos_dev_mmap) */
int koruos_memfd_mmap(struct vfscore_file *f, off_t offset, size_t len, __paddr_t *paddr)
{
	struct vnode *vp = f->f_dentry ? f->f_dentry->d_vnode : NULL;
	struct km *m = vp && vp->v_type == VCHR ? km_of(vp->v_data) : NULL;
	int rc;

	if (!m)
		return -ENODEV;
	if (offset < 0 || (offset & 0xfff))
		return -EINVAL;
	if ((rc = km_alloc(m, MAX(km_len(m), (size_t)offset + len))))
		return -rc;
	if ((size_t)offset + len > m->size)
		return -EINVAL;
	*paddr = m->pa + offset;
	return 0;
}

#define MFD_CLOEXEC 1U
#define MFD_ALLOW_SEALING 2U
#define MFD_NOEXEC_SEAL 8U
#define MFD_EXEC 0x10U

UK_SYSCALL_R_DEFINE(int, memfd_create, const char *, name, unsigned int, flags)
{
	char path[40];
	long fd;
	struct vfscore_file *f;
	int i;

	if (flags & ~(MFD_CLOEXEC | MFD_ALLOW_SEALING | MFD_NOEXEC_SEAL | MFD_EXEC)) {
		uk_pr_err("koru-os: REFUSED linux.sys.memfd_create flags 0x%x\n", flags);
		return -EINVAL;
	}
	(void)name;
	for (i = 0; i < KM_SLOTS && M[i].used; i++)
		;
	if (i == KM_SLOTS || !M[i].dev)
		return -EMFILE;
	M[i].used = 1;
	M[i].size = 0;
	snprintf(path, sizeof(path), "/dev/.korumemfd%d", i);
	fd = uk_syscall_r_open((long)path, (long)(O_RDWR | ((flags & MFD_CLOEXEC) ? O_CLOEXEC : 0)), 0);
	if (fd < 0) {
		M[i].used = 0;
		return fd;
	}
	f = vfscore_get_file((int)fd);
	if (f) {
		M[i].vp = f->f_dentry ? f->f_dentry->d_vnode : NULL;
		if (M[i].vp)
			M[i].vp->v_size = 0;
		fdrop(f);
	}
	return fd;
}

static int km_init(struct uk_init_ctx *ictx __unused)
{
	for (int i = 0; i < KM_SLOTS; i++) {
		char n[24];

		snprintf(n, sizeof(n), ".korumemfd%d", i);
		if (device_create(&km_drv, n, D_CHR, &M[i].dev))
			M[i].dev = NULL;
	}
	return 0;
}
uk_late_initcall(km_init, 0);
