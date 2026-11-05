/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os: virtio-gpu scanout provider, binding the kms.* rows (kms_rows.h)
 * for QEMU `virtio-gpu-pci` (virtio 1.0, 2D only — no virgl).
 *
 * The provider fills kms.vram with a page-allocated guest region attached
 * to a host 2D resource (ATTACH_BACKING); kms.scanout is SET_SCANOUT +
 * TRANSFER_TO_HOST_2D + FLUSH; kms.disable is SET_SCANOUT with no resource.
 * No Linux code; written from the virtio 1.0 and virtio-gpu specs. The
 * transport shape follows the same-author koru-desktop drm-virtio-gpu
 * driver (BSD-3-Clause), re-derived here against the specs.
 */
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <uk/print.h>
#include <uk/init.h>
#include <uk/alloc.h>
#include <uk/arch/util.h>
#include <uk/bus/pci.h>
#include <uk/vmem.h>
#include <uk/paging.h>
#include <devfs/device.h>
#include "kms_rows.h"
#include "korusysfs.h"

/* ---------- PCI config space (port I/O, same shape as bochs.c) ---------- */

static uint32_t cfg_read32(const struct pci_address *a, uint8_t reg)
{
	uk_arch_x86_64_outl(PCI_CONFIG_ADDR, PCI_ENABLE_BIT
			    | ((uint32_t)a->bus << PCI_BUS_SHIFT)
			    | ((uint32_t)a->devid << PCI_DEVICE_SHIFT)
			    | ((uint32_t)a->function << PCI_FUNCTION_SHIFT)
			    | (reg & 0xfc));
	return uk_arch_x86_64_inl(PCI_CONFIG_DATA);
}

static uint8_t cfg_read8(const struct pci_address *a, uint8_t reg)
{
	return (cfg_read32(a, reg) >> ((reg & 3) * 8)) & 0xff;
}

static void cfg_write32(const struct pci_address *a, uint8_t reg, uint32_t v)
{
	uk_arch_x86_64_outl(PCI_CONFIG_ADDR, PCI_ENABLE_BIT
			    | ((uint32_t)a->bus << PCI_BUS_SHIFT)
			    | ((uint32_t)a->devid << PCI_DEVICE_SHIFT)
			    | ((uint32_t)a->function << PCI_FUNCTION_SHIFT)
			    | (reg & 0xfc));
	uk_arch_x86_64_outl(PCI_CONFIG_DATA, v);
}

static uint64_t bar_addr(const struct pci_address *a, int i)
{
	uint32_t lo = cfg_read32(a, PCI_BASE_ADDRESS_0 + 4 * i);

	if (lo & 1)
		return 0; /* I/O BAR */
	if (((lo >> 1) & 3) == 2) /* 64-bit */
		return ((uint64_t)cfg_read32(a, PCI_BASE_ADDRESS_0 + 4 * i + 4)
			<< 32) | (lo & ~0xfULL);
	return lo & ~0xfULL;
}

static int map_phys(uint64_t paddr, size_t len, const char *name, void **out)
{
	__vaddr_t va = UK_PAGING_VADDR_ANY;
	int rc;

	rc = uk_vma_map_dma(uk_vas_get_active(), &va, len,
			    UK_PAGING_PAGE_ATTR_PROT_RW, UK_VMA_MAP_POPULATE,
			    name, paddr);
	if (rc)
		return rc;
	*out = (void *)va;
	return 0;
}

/* ---------- virtio 1.0 caps / split virtqueue ---------- */

struct vcap { uint8_t type, bar; uint32_t off, len, mul; };
static uint64_t common, notify;

static void *mmio(uint64_t a)
{
	static void *va_cache[8];
	static uint64_t pa_cache[8];
	static int nmap;

	for (int i = 0; i < nmap; i++)
		if (pa_cache[i] == (a & ~0xfffULL))
			return (char *)va_cache[i] + (a & 0xfff);
	if (nmap == 8)
		return NULL;
	void *v;
	if (map_phys(a & ~0xfffULL, 0x1000, "vgpu-bar", &v))
		return NULL;
	pa_cache[nmap] = a & ~0xfffULL;
	va_cache[nmap++] = v;
	return (char *)v + (a & 0xfff);
}

#define mw8(a, v)  (*(volatile uint8_t *)mmio(a) = (v))
#define mw16(a, v) (*(volatile uint16_t *)mmio(a) = (v))
#define mw32(a, v) (*(volatile uint32_t *)mmio(a) = (v))
#define mw64(a, v) (*(volatile uint64_t *)mmio(a) = (v))
#define mr8(a)  (*(volatile uint8_t *)mmio(a))
#define mr16(a) (*(volatile uint16_t *)mmio(a))
#define mr32(a) (*(volatile uint32_t *)mmio(a))
#define phys(p) ((uint64_t)uk_paging_virt_to_phys((__vaddr_t)(p)))

struct vdesc { uint64_t addr; uint32_t len; uint16_t flags, next; } __attribute__((packed));
struct vavail { uint16_t flags, idx, ring[0]; };
struct vused_elem { uint32_t id, len; };
struct vused { uint16_t flags, idx; struct vused_elem ring[0]; };

struct vq {
	int idx, n;
	uint16_t last_used;
	struct vdesc *desc;
	struct vavail *avail;
	struct vused *used;
	uint64_t notify_addr;
};

static struct vq ctrlv;
static uint32_t noff; /* notify_off_multiplier */

static int vq_setup(const struct pci_address *a, struct vq *q, int idx)
{
	uint16_t sz;
	void *m;
	uintptr_t p;

	mw16(common + 0x16, idx);		/* queue_select */
	sz = mr16(common + 0x18);		/* queue_size */
	if (!sz)
		return -1;
	memset(q, 0, sizeof(*q));
	q->idx = idx;
	q->n = sz;
	m = uk_malloc(uk_alloc_get_default(),
		      sz * 16 + 16 + sz * 2 + 16 + sz * 8 + 64);
	if (!m)
		return -1;
	p = (uintptr_t)m;
	q->desc  = (struct vdesc *)p;  p += sz * 16;
	p = (p + 15) & ~15ul;
	q->avail = (struct vavail *)p; p += 4 + sz * 2 + 2;
	p = (p + 15) & ~15ul;
	q->used  = (struct vused *)p;
	memset(q->desc, 0, sz * 16);
	memset(q->avail, 0, 4 + sz * 2 + 2);
	memset(q->used, 0, 4 + sz * 8);
	q->notify_addr = notify + (uint64_t)mr16(common + 0x1e) * noff;
	mw64(common + 0x20, phys(q->desc));
	mw64(common + 0x28, phys(q->avail));
	mw64(common + 0x30, phys(q->used));
	mw16(common + 0x1c, 1);			/* queue_enable */
	uk_pr_info("koru-os: vgpu: ctrlq size=%u\n", sz);
	(void)a;
	return 0;
}

/* submit a 2-desc out+in command, poll the used ring for completion */
static int vq_xfer(struct vq *q, void *out, int outlen, void *in, int inlen)
{
	q->desc[0].addr = phys(out);
	q->desc[0].len = outlen;
	q->desc[0].flags = 1;			/* NEXT */
	q->desc[0].next = 1;
	q->desc[1].addr = phys(in);
	q->desc[1].len = inlen;
	q->desc[1].flags = 2;			/* WRITE */
	q->desc[1].next = 0;
	__sync_synchronize();
	q->avail->ring[q->avail->idx % q->n] = 0;
	__sync_synchronize();
	q->avail->idx++;
	__sync_synchronize();
	mw16(q->notify_addr, q->idx);
	for (volatile long i = 0; i < 200000000; i++)
		if (((volatile struct vused *)q->used)->idx != q->last_used) {
			uint16_t ui = q->last_used % q->n;
			q->last_used++;
			return q->used->ring[ui].len;
		}
	return -1;
}

/* ---------- virtio-gpu protocol ---------- */

struct gpu_hdr { uint32_t type, flags; uint64_t fence_id; uint32_t ctx_id, pad; };
struct gpu_rect { uint32_t x, y, w, h; };
struct gpu_display_one { uint32_t enabled; struct gpu_rect r; uint32_t flags; };
struct gpu_display_info {
	struct gpu_hdr hdr;
	struct gpu_display_one pmodes[16];
};
struct gpu_res_create_2d {
	struct gpu_hdr hdr; uint32_t resource_id, format, w, h;
};
struct gpu_mem_entry { uint64_t addr; uint32_t len, pad; };
struct gpu_attach_backing {
	struct gpu_hdr hdr; uint32_t resource_id, nr_entries;
	struct gpu_mem_entry e[1];
};
struct gpu_set_scanout {
	struct gpu_hdr hdr; struct gpu_rect r; uint32_t scanout_id, resource_id;
};
struct gpu_transfer_2d {
	struct gpu_hdr hdr; struct gpu_rect r; uint64_t offset; uint32_t resource_id, pad;
};
struct gpu_flush {
	struct gpu_hdr hdr; struct gpu_rect r; uint32_t resource_id, pad;
};

#define CMD_GET_DISPLAY_INFO	0x0100
#define CMD_RESOURCE_CREATE_2D	0x0101
#define CMD_SET_SCANOUT		0x0103
#define CMD_RESOURCE_FLUSH	0x0104
#define CMD_TRANSFER_2D		0x0105
#define CMD_ATTACH_BACKING	0x0106
#define RESP_OK_NODATA		0x1100
#define RESP_OK_DISPLAY_INFO	0x1101
#define RESP_ERR_UNSPEC		0x1200
#define FMT_B8G8R8X8		1

static uint8_t respbuf[1024];

static int gpu_cmd(void *cmd, int len, int rlen)
{
	int r;

	memset(respbuf, 0, rlen);
	r = vq_xfer(&ctrlv, cmd, len, respbuf, rlen);
	if (r < 0)
		return -1;
	return (int)((struct gpu_hdr *)respbuf)->type;
}

/* ---------- the provider ---------- */

#define VGPU_VRAM_SIZE (16 << 20)	/* 16 MiB scanout pool */
#define VGPU_RID       1

static struct {
	int found;
	struct pci_address addr;
	struct kms_provider p;
	uint32_t pitch;		/* resource geometry currently bound */
	uint64_t res_w, res_h;
} vgpu;

static int vgpu_bind_resource(uint32_t pitch, uint32_t rows)
{
	uint32_t rw = pitch / 4, rh = rows;
	struct gpu_res_create_2d rc = { .hdr.type = CMD_RESOURCE_CREATE_2D,
	    .resource_id = VGPU_RID, .format = FMT_B8G8R8X8, .w = rw, .h = rh };
	struct gpu_attach_backing ab = { .hdr.type = CMD_ATTACH_BACKING,
	    .resource_id = VGPU_RID, .nr_entries = 1 };
	int t;

	if (vgpu.pitch == pitch && vgpu.res_h >= rows)
		return 0;
	t = gpu_cmd(&rc, sizeof(rc), 8);
	if (t != RESP_OK_NODATA) {
		uk_pr_err("koru-os: vgpu: create2d %ux%u: resp=%x\n", rw, rh, t);
		return -1;
	}
	/* The guest buffer is only VA-contiguous — QEMU maps each entry's
	 * phys independently, so emit one entry per contiguous phys run. */
	{
		static uint8_t abuf[16448];	/* 32 + 1024*16 */
		struct gpu_attach_backing *ab2 = (void *)abuf;
		uint32_t total = rw * rh * 4, n = 0, i;
		uint64_t run_start = 0, run_end = 0;
		ab2->hdr.type = CMD_ATTACH_BACKING;
		ab2->resource_id = VGPU_RID;
		for (i = 0; i * 4096 < total && n < 1020; i++) {
			uint64_t p = phys((char *)vgpu.p.vram_virt + i * 4096);
			if (i && p == run_end)
				run_end += 4096;
			else {
				if (i) {
					ab2->e[n].addr = run_start;
					ab2->e[n].len = run_end - run_start;
					ab2->e[n].pad = 0;
					n++;
				}
				run_start = p;
				run_end = p + 4096;
			}
		}
		ab2->e[n].addr = run_start;
		ab2->e[n].len = run_end - run_start;
		ab2->e[n].pad = 0;
		n++;
		if (n >= 1020) {
			uk_pr_err("koru-os: vgpu: backing needs %u runs — too fragmented\n", n);
			return -1;
		}
		ab2->nr_entries = n;
		t = gpu_cmd(ab2, 24 + 8 + n * 16, 8);
	}
	if (t != RESP_OK_NODATA) {
		uk_pr_err("koru-os: vgpu: attach: resp=%x r0=%08x r1=%08x\n",
			  t, ((uint32_t *)respbuf)[0], ((uint32_t *)respbuf)[1]);
		return -1;
	}
	vgpu.pitch = pitch;
	vgpu.res_w = rw;
	vgpu.res_h = rh;
	uk_pr_info("koru-os: vgpu: resource %ux%u bound to vram\n", rw, rh);
	return 0;
}

static int vgpu_scanout(struct kms_provider *p, uint64_t offset, uint32_t w,
			uint32_t h, uint32_t pitch)
{
	uint32_t x = (offset % pitch) / 4, y = offset / pitch;
	struct gpu_set_scanout so = { .hdr.type = CMD_SET_SCANOUT,
	    .r = { x, y, w, h }, .scanout_id = 0, .resource_id = VGPU_RID };
	struct gpu_flush fl = { .hdr.type = CMD_RESOURCE_FLUSH,
	    .r = { x, y, w, h }, .resource_id = VGPU_RID };
	struct gpu_transfer_2d tr = { .hdr.type = CMD_TRANSFER_2D,
	    .r = { x, y, w, h }, .resource_id = VGPU_RID };
	int t;

	if (offset + (uint64_t)pitch * h > p->vram_size)
		return -EINVAL;
	if (vgpu_bind_resource(pitch, y + h))
		return -EIO;
	t = gpu_cmd(&so, sizeof(so), 8);
	if (t != RESP_OK_NODATA) {
		uk_pr_err("koru-os: vgpu: set_scanout: resp=%x\n", t);
		return -EIO;
	}
	/* TRANSFER reads the backing packed: full-width rows transfer in one
	 * command; a cropped rect (x != 0 or w < pitch/4) transfers per row. */
	if (x == 0 && w == vgpu.res_w) {
		tr.offset = offset;
		t = gpu_cmd(&tr, sizeof(tr), 8);
		if (t != RESP_OK_NODATA)
			goto xerr;
	} else {
		for (uint32_t i = 0; i < h; i++) {
			struct gpu_transfer_2d row = tr;
			row.r.y = y + i;
			row.r.h = 1;
			row.offset = offset + (uint64_t)i * pitch;
			t = gpu_cmd(&row, sizeof(row), 8);
			if (t != RESP_OK_NODATA)
				goto xerr;
		}
	}
	t = gpu_cmd(&fl, sizeof(fl), 8);
	if (t != RESP_OK_NODATA)
		goto xerr;
	uk_pr_info("koru-os: kms.scanout %s %ux%u pitch %u offset 0x%lx\n",
		   p->name, w, h, pitch, (unsigned long)offset);
	return 0;
xerr:
	uk_pr_err("koru-os: vgpu: transfer/flush: resp=%x\n", t);
	return -EIO;
}

static int vgpu_disable(struct kms_provider *p __unused)
{
	struct gpu_set_scanout so = { .hdr.type = CMD_SET_SCANOUT,
	    .scanout_id = 0, .resource_id = 0 };
	int t = gpu_cmd(&so, sizeof(so), 8);

	return t == RESP_OK_NODATA ? 0 : -EIO;
}

static void add_mode(uint32_t w, uint32_t h, int preferred)
{
	struct kms_mode *m;

	if (vgpu.p.nmodes >= KMS_MAX_MODES)
		return;
	m = &vgpu.p.modes[vgpu.p.nmodes++];
	memset(m, 0, sizeof(*m));
	m->clock = 65000;
	m->hdisplay = m->htotal = w;
	m->vdisplay = m->vtotal = h;
	m->vrefresh = 60;
	m->type = preferred ? 1 << 6 : 1 << 4;	/* PREFERRED : DRIVER */
	snprintf(m->name, sizeof(m->name), "%ux%u", w, h);
}

static void publish_sysfs(void)
{
	static char dev[64], ue[512], f[96], v[32];
	uint32_t id = cfg_read32(&vgpu.addr, 0x00);
	uint32_t cr = cfg_read32(&vgpu.addr, 0x08);
	uint32_t ss = cfg_read32(&vgpu.addr, 0x2c);
	unsigned int ven = id & 0xffff, did = id >> 16, cls = cr >> 8, rev = cr & 0xff;
	unsigned int sven = ss & 0xffff, sdid = ss >> 16;
	static const char *const attr[] = { "vendor", "device", "subsystem_vendor",
					    "subsystem_device", "class", "revision" };
	unsigned int val[] = { ven, did, sven, sdid, cls, rev };
	int i;

	snprintf(dev, sizeof(dev), "pci%04x:%02x/%04x:%02x:%02x.%x",
		 vgpu.addr.domain, vgpu.addr.bus, vgpu.addr.domain,
		 vgpu.addr.bus, vgpu.addr.devid, vgpu.addr.function);
	snprintf(ue, sizeof(ue),
		 "DRIVER=koru-vgpu\nPCI_CLASS=%X\nPCI_ID=%04X:%04X\n"
		 "PCI_SUBSYS_ID=%04X:%04X\nPCI_SLOT_NAME=%s\n"
		 "MODALIAS=pci:v%08Xd%08Xsv%08Xsd%08Xbc%02Xsc%02Xi%02X\n",
		 cls, ven, did, sven, sdid, strchr(dev, '/') + 1,
		 ven, did, sven, sdid, cls >> 16, (cls >> 8) & 0xff, cls & 0xff);
	snprintf(f, sizeof(f), "pci%04x:%02x", vgpu.addr.domain, vgpu.addr.bus);
	korusysfs_device(f, NULL, "", NULL);
	korusysfs_device(dev, "bus/pci", ue, NULL);
	for (i = 0; i < 6; i++) {
		snprintf(f, sizeof(f), "devices/%s/%s", dev, attr[i]);
		snprintf(v, sizeof(v), i == 4 ? "0x%06x\n" : i == 5 ? "0x%02x\n" : "0x%04x\n", val[i]);
		korusysfs_file(f, v);
	}
	vgpu.p.sys_parent = dev;
}

static int vgpu_add_dev(struct pci_device *dev)
{
	if (dev->id.vendor_id == 0x1af4 &&
	    (dev->id.device_id == 0x1050 || dev->id.device_id == 0x1010)) {
		vgpu.found = 1;
		vgpu.addr = dev->addr;
	}
	return 0;
}

static const struct pci_device_id vgpu_ids[] = {
	{ PCI_DEVICE_ID(0x1af4, 0x1050) },
	{ PCI_DEVICE_ID(0x1af4, 0x1010) },
	{ PCI_ANY_DEVICE_ID },
};

static struct pci_driver vgpu_pci_drv = {
	.device_ids = vgpu_ids,
	.add_dev = vgpu_add_dev,
};

PCI_REGISTER_DRIVER(&vgpu_pci_drv);

/* Runs at the rootfs stage: the PCI bus has been probed, vmem is up. */
static int vgpu_bind(struct uk_init_ctx *ictx __unused)
{
	struct vcap caps[8];
	uint32_t cmd;
	int i, ncaps = 0;
	uint8_t cp, st;

	if (!vgpu.found) {
		uk_pr_info("koru-os: kms: no virtio-gpu on the PCI bus\n");
		return 0;
	}
	cmd = cfg_read32(&vgpu.addr, PCI_COMMAND);
	cfg_write32(&vgpu.addr, PCI_COMMAND, cmd | PCI_COMMAND_MEMORY);

	/* virtio 1.0 capability walk: common(1)/notify(2)/isr(3) BARs */
	cp = cfg_read8(&vgpu.addr, 0x34);
	while (cp && cp >= 0x40 && ncaps < 8) {
		uint8_t id = cfg_read8(&vgpu.addr, cp);
		uint8_t nxt = cfg_read8(&vgpu.addr, cp + 1);
		if (id == 0x09 && cfg_read8(&vgpu.addr, cp + 2) >= 16) {
			struct vcap *c = &caps[ncaps];
			c->type = cfg_read8(&vgpu.addr, cp + 3);
			c->bar  = cfg_read8(&vgpu.addr, cp + 4);
			c->off  = cfg_read32(&vgpu.addr, cp + 8);
			c->len  = cfg_read32(&vgpu.addr, cp + 12);
			c->mul  = cfg_read8(&vgpu.addr, cp + 2) >= 20
				? cfg_read32(&vgpu.addr, cp + 16) : 0;
			ncaps++;
		}
		cp = nxt;
	}
	for (i = 0; i < ncaps; i++) {
		uint64_t b = bar_addr(&vgpu.addr, caps[i].bar);
		if (caps[i].type == 1) common = b + caps[i].off;
		if (caps[i].type == 2) notify = b + caps[i].off;
		if (caps[i].type == 3) noff = caps[i].mul;
	}
	if (!common || !notify) {
		uk_pr_err("koru-os: vgpu: no virtio caps\n");
		return 0;
	}

	/* status protocol + VERSION_1 */
	mw8(common + 0x14, 0);
	mw8(common + 0x14, 1);
	st = mr8(common + 0x14);
	mw8(common + 0x14, st | 2);
	mw32(common + 0x08, 1);
	mw32(common + 0x0c, 1);			/* VERSION_1 */
	st = mr8(common + 0x14);
	mw8(common + 0x14, st | 8);
	st = mr8(common + 0x14);
	if (!(st & 8)) {
		uk_pr_err("koru-os: vgpu: features st=%x\n", st);
		return 0;
	}
	mw8(common + 0x14, st | 4);		/* DRIVER_OK */
	if (vq_setup(&vgpu.addr, &ctrlv, 0)) {
		uk_pr_err("koru-os: vgpu: no ctrlq\n");
		return 0;
	}

	/* modes from GET_DISPLAY_INFO; QEMU gives rects, we synthesise
	 * conservative 60 Hz timings (drm personality only reads
	 * hdisplay/vdisplay/name/type). */
	{
		struct gpu_hdr gc = { .type = CMD_GET_DISPLAY_INFO };
		struct gpu_display_info *di = (void *)respbuf;
		int t = gpu_cmd(&gc, sizeof(gc), sizeof(*di));
		int first = 1;

		if (t == RESP_OK_DISPLAY_INFO) {
			for (i = 0; i < 16; i++)
				if (di->pmodes[i].enabled) {
					add_mode(di->pmodes[i].r.w,
						 di->pmodes[i].r.h, first);
					if (first) {
						vgpu.p.max_width = di->pmodes[i].r.w;
						vgpu.p.max_height = di->pmodes[i].r.h;
					}
					first = 0;
				}
		}
		if (!vgpu.p.nmodes) {
			add_mode(640, 480, 1);
			vgpu.p.max_width = 640;
			vgpu.p.max_height = 480;
		}
	}

	/* kms.vram: a page-allocated guest region attached as a host 2D
	 * resource (virtio-gpu has no exposed VRAM BAR). */
	vgpu.p.vram_size = VGPU_VRAM_SIZE;
	/* QEMU's dma_map refuses phys ranges spanning the ISA hole
	 * (0xa0000-0xfffff). Bump the page heap until the pool lands clear
	 * of it — losers stay allocated (bounded leak, a few pages). */
	for (int t = 0; t < 16; t++) {
		void *v = uk_palloc(uk_alloc_get_default(),
				    VGPU_VRAM_SIZE / 0x1000);
		uint64_t p = v ? phys(v) : 0;
		if (!v) break;
		if (p >= 0x100000 || p + VGPU_VRAM_SIZE <= 0xa0000) {
			vgpu.p.vram_virt = v;
			vgpu.p.vram_phys = p;
			break;
		}
	}
	if (!vgpu.p.vram_virt) {
		uk_pr_err("koru-os: vgpu: vram alloc failed\n");
		return 0;
	}
	memset(vgpu.p.vram_virt, 0, VGPU_VRAM_SIZE);

	vgpu.p.name = "virtio-gpu";
	vgpu.p.connected = 1;
	vgpu.p.mm_width = 0;
	vgpu.p.mm_height = 0;
	vgpu.p.scanout = vgpu_scanout;
	vgpu.p.disable = vgpu_disable;
	uk_pr_info("koru-os: kms: virtio-gpu %02x:%02x.%x VRAM %lu MiB at phys 0x%lx, %u modes (first %s)\n",
		   vgpu.addr.bus, vgpu.addr.devid, vgpu.addr.function,
		   (unsigned long)(vgpu.p.vram_size >> 20),
		   (unsigned long)vgpu.p.vram_phys,
		   vgpu.p.nmodes, vgpu.p.nmodes ? vgpu.p.modes[0].name : "-");
	publish_sysfs();
	i = kms_rows_bind(&vgpu.p);
	if (i)
		uk_pr_err("koru-os: kms: bind rows: %d\n", i);
	return 0;
}
devfs_initcall(vgpu_bind);
