/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M6: native scanout provider for QEMU bochs-display (and the QEMU
 * standard VGA, which has the same PCI id and the same MMIO BAR layout).
 * It binds the kms.* rows (kms_rows.h). No Linux code; written from the
 * QEMU device model's register layout (DISPI interface, BAR2 + 0x500,
 * EDID at BAR2 + 0x000).
 */
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <uk/print.h>
#include <uk/init.h>
#include <uk/arch/util.h>
#include <uk/bus/pci.h>
#include <uk/vmem.h>
#include <uk/paging.h>
#include <devfs/device.h>
#include "kms_rows.h"
#include "korusysfs.h"

#define BOCHS_VENDOR 0x1234
#define BOCHS_DEVICE 0x1111

#define DISPI_OFF        0x500
#define DISPI_ID         0x0
#define DISPI_XRES       0x1
#define DISPI_YRES       0x2
#define DISPI_BPP        0x3
#define DISPI_ENABLE     0x4
#define DISPI_BANK       0x5
#define DISPI_VIRT_WIDTH 0x6
#define DISPI_VIRT_HEIGHT 0x7
#define DISPI_X_OFFSET   0x8
#define DISPI_Y_OFFSET   0x9
#define DISPI_VIDEO_MEMORY_64K 0xa
#define DISPI_ENABLED    0x01
#define DISPI_LFB_ENABLED 0x40

static struct {
	int found;
	struct pci_address addr;
	uint64_t bar0, bar2;
	volatile uint16_t *dispi;
	volatile uint8_t *edid;
	struct kms_provider p;
} bochs;

static uint32_t cfg_read32(const struct pci_address *a, uint8_t reg)
{
	uk_arch_x86_64_outl(PCI_CONFIG_ADDR, PCI_ENABLE_BIT
			    | ((uint32_t)a->bus << PCI_BUS_SHIFT)
			    | ((uint32_t)a->devid << PCI_DEVICE_SHIFT)
			    | ((uint32_t)a->function << PCI_FUNCTION_SHIFT)
			    | (reg & 0xfc));
	return uk_arch_x86_64_inl(PCI_CONFIG_DATA);
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

static void dispi_w(uint16_t idx, uint16_t v) { bochs.dispi[idx] = v; }
static uint16_t dispi_r(uint16_t idx) { return bochs.dispi[idx]; }

static int bochs_scanout(struct kms_provider *p, uint64_t offset, uint32_t w,
			 uint32_t h, uint32_t pitch)
{
	uint32_t vw = pitch / 4;

	if (pitch % 4 || w > vw || offset + (uint64_t)pitch * h > p->vram_size)
		return -EINVAL;
	dispi_w(DISPI_ENABLE, 0);
	dispi_w(DISPI_BPP, 32);
	dispi_w(DISPI_XRES, w);
	dispi_w(DISPI_YRES, h);
	dispi_w(DISPI_BANK, 0);
	dispi_w(DISPI_VIRT_WIDTH, vw);
	dispi_w(DISPI_VIRT_HEIGHT, (uint16_t)((p->vram_size - offset) / pitch));
	dispi_w(DISPI_X_OFFSET, (offset % pitch) / 4);
	dispi_w(DISPI_Y_OFFSET, offset / pitch);
	dispi_w(DISPI_ENABLE, DISPI_ENABLED | DISPI_LFB_ENABLED);
	uk_pr_info("koru-os: kms.scanout %s %ux%u pitch %u offset 0x%lx\n",
		   p->name, w, h, pitch, (unsigned long)offset);
	return 0;
}

static int bochs_disable(struct kms_provider *p __unused)
{
	dispi_w(DISPI_ENABLE, 0);
	return 0;
}

static void add_mode(uint32_t clock, uint16_t hd, uint16_t hss, uint16_t hse,
		     uint16_t ht, uint16_t vd, uint16_t vss, uint16_t vse,
		     uint16_t vt, uint32_t flags, uint32_t type)
{
	struct kms_mode *m;
	uint32_t i;

	for (i = 0; i < bochs.p.nmodes; i++)
		if (bochs.p.modes[i].hdisplay == hd
		    && bochs.p.modes[i].vdisplay == vd)
			return;
	if (bochs.p.nmodes >= KMS_MAX_MODES || hd > bochs.p.max_width
	    || vd > bochs.p.max_height
	    || (uint64_t)hd * vd * 4 > bochs.p.vram_size)
		return;
	m = &bochs.p.modes[bochs.p.nmodes++];
	memset(m, 0, sizeof(*m));
	m->clock = clock;
	m->hdisplay = hd; m->hsync_start = hss; m->hsync_end = hse;
	m->htotal = ht;
	m->vdisplay = vd; m->vsync_start = vss; m->vsync_end = vse;
	m->vtotal = vt;
	m->vrefresh = (uint32_t)(((uint64_t)clock * 1000 + (uint64_t)ht * vt / 2)
				 / ((uint64_t)ht * vt));
	m->flags = flags;
	m->type = type;
	snprintf(m->name, sizeof(m->name), "%ux%u", hd, vd);
}

/* First detailed timing descriptor of a QEMU-generated EDID block. */
static void edid_modes(void)
{
	const volatile uint8_t *e = bochs.edid;
	static const uint8_t hdr[8] = {0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0};
	const volatile uint8_t *d = e + 54;
	uint32_t clk, ha, hb, va, vb, hso, hsw, vso, vsw;
	int i;

	for (i = 0; i < 8; i++)
		if (e[i] != hdr[i])
			return;
	clk = (d[0] | (d[1] << 8)) * 10;
	if (!clk)
		return;
	ha = d[2] | ((d[4] & 0xf0) << 4);
	hb = d[3] | ((d[4] & 0x0f) << 8);
	va = d[5] | ((d[7] & 0xf0) << 4);
	vb = d[6] | ((d[7] & 0x0f) << 8);
	hso = d[8] | ((d[11] & 0xc0) << 2);
	hsw = d[9] | ((d[11] & 0x30) << 4);
	vso = (d[10] >> 4) | ((d[11] & 0x0c) << 2);
	vsw = (d[10] & 0x0f) | ((d[11] & 0x03) << 4);
	bochs.p.mm_width = d[12] | ((d[14] & 0xf0) << 4);
	bochs.p.mm_height = d[13] | ((d[14] & 0x0f) << 8);
	add_mode(clk, ha, ha + hso, ha + hso + hsw, ha + hb,
		 va, va + vso, va + vso + vsw, va + vb,
		 ((d[17] & 0x02) ? 0x1 : 0x2) | ((d[17] & 0x04) ? 0x4 : 0x8),
		 (1 << 3) | (1 << 6)); /* PREFERRED | DRIVER */
}

static int bochs_add_dev(struct pci_device *dev)
{
	if (bochs.found) {
		uk_pr_warn("koru-os: bochs: only one display is driven\n");
		return 0;
	}
	bochs.found = 1;
	bochs.addr = dev->addr;
	return 0;
}

static const struct pci_device_id bochs_ids[] = {
	{PCI_DEVICE_ID(BOCHS_VENDOR, BOCHS_DEVICE)},
	{PCI_ANY_DEVICE_ID},
};

static struct pci_driver bochs_pci_drv = {
	.device_ids = bochs_ids,
	.add_dev = bochs_add_dev,
};
PCI_REGISTER_DRIVER(&bochs_pci_drv);

/* M7b: the PCI device in the sysfs view, from its config space */
static void publish_sysfs(void)
{
	static char dev[64], ue[512], f[96], v[32];
	uint32_t id = cfg_read32(&bochs.addr, 0x00);
	uint32_t cr = cfg_read32(&bochs.addr, 0x08);
	uint32_t ss = cfg_read32(&bochs.addr, 0x2c);
	unsigned int ven = id & 0xffff, did = id >> 16, cls = cr >> 8, rev = cr & 0xff;
	unsigned int sven = ss & 0xffff, sdid = ss >> 16;
	static const char *const attr[] = { "vendor", "device", "subsystem_vendor",
					    "subsystem_device", "class", "revision" };
	unsigned int val[] = { ven, did, sven, sdid, cls, rev };
	int i;

	snprintf(dev, sizeof(dev), "pci%04x:%02x/%04x:%02x:%02x.%x",
		 bochs.addr.domain, bochs.addr.bus, bochs.addr.domain,
		 bochs.addr.bus, bochs.addr.devid, bochs.addr.function);
	snprintf(ue, sizeof(ue),
		 "DRIVER=koru-bochs\nPCI_CLASS=%X\nPCI_ID=%04X:%04X\n"
		 "PCI_SUBSYS_ID=%04X:%04X\nPCI_SLOT_NAME=%s\n"
		 "MODALIAS=pci:v%08Xd%08Xsv%08Xsd%08Xbc%02Xsc%02Xi%02X\n",
		 cls, ven, did, sven, sdid, strchr(dev, '/') + 1,
		 ven, did, sven, sdid, cls >> 16, (cls >> 8) & 0xff, cls & 0xff);
	snprintf(f, sizeof(f), "pci%04x:%02x", bochs.addr.domain, bochs.addr.bus);
	korusysfs_device(f, NULL, "", NULL);
	korusysfs_device(dev, "bus/pci", ue, NULL);
	for (i = 0; i < 6; i++) {
		snprintf(f, sizeof(f), "devices/%s/%s", dev, attr[i]);
		snprintf(v, sizeof(v), i == 4 ? "0x%06x\n" : i == 5 ? "0x%02x\n" : "0x%04x\n", val[i]);
		korusysfs_file(f, v);
	}
	bochs.p.sys_parent = dev;
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

/* Runs at the rootfs stage: the PCI bus has been probed, vmem is up. */
static int bochs_bind(struct uk_init_ctx *ictx __unused)
{
	void *mmio, *vram;
	uint16_t id;
	uint32_t cmd;
	int rc;

	if (!bochs.found) {
		uk_pr_info("koru-os: kms: no bochs-display/stdvga on the PCI bus\n");
		return 0;
	}
	cmd = cfg_read32(&bochs.addr, PCI_COMMAND);
	cfg_write32(&bochs.addr, PCI_COMMAND, cmd | PCI_COMMAND_MEMORY);
	bochs.bar0 = bar_addr(&bochs.addr, 0);
	bochs.bar2 = bar_addr(&bochs.addr, 2);
	if (!bochs.bar0 || !bochs.bar2) {
		uk_pr_err("koru-os: bochs: BAR0 0x%lx BAR2 0x%lx not usable\n",
			  (unsigned long)bochs.bar0, (unsigned long)bochs.bar2);
		return 0;
	}
	rc = map_phys(bochs.bar2, 0x1000, "bochs-mmio", &mmio);
	if (rc) {
		uk_pr_err("koru-os: bochs: map MMIO: %d\n", rc);
		return 0;
	}
	bochs.edid = mmio;
	bochs.dispi = (volatile uint16_t *)((char *)mmio + DISPI_OFF);
	id = dispi_r(DISPI_ID);
	if (id < 0xb0c0 || id > 0xb0cf) {
		uk_pr_err("koru-os: bochs: DISPI id 0x%x unknown\n", id);
		return 0;
	}
	bochs.p.name = "bochs-display";
	bochs.p.vram_phys = bochs.bar0;
	bochs.p.vram_size = (uint64_t)dispi_r(DISPI_VIDEO_MEMORY_64K) << 16;
	rc = map_phys(bochs.bar0, bochs.p.vram_size, "bochs-vram", &vram);
	if (rc) {
		uk_pr_err("koru-os: bochs: map VRAM: %d\n", rc);
		return 0;
	}
	bochs.p.vram_virt = vram;
	bochs.p.max_width = 2560;
	bochs.p.max_height = 1600;
	bochs.p.connected = 1;
	bochs.p.mm_width = 0;
	bochs.p.mm_height = 0;
	edid_modes();
	add_mode(65000, 1024, 1048, 1184, 1344, 768, 771, 777, 806, 0x2 | 0x8,
		 1 << 6);
	add_mode(40000, 800, 840, 968, 1056, 600, 601, 605, 628, 0x1 | 0x4,
		 1 << 6);
	add_mode(25175, 640, 656, 752, 800, 480, 490, 492, 525, 0x2 | 0x8,
		 1 << 6);
	bochs.p.scanout = bochs_scanout;
	bochs.p.disable = bochs_disable;
	uk_pr_info("koru-os: kms: bochs-display %02x:%02x.%x DISPI 0x%x, VRAM %lu KiB at 0x%lx, MMIO 0x%lx, %u modes (first %s)\n",
		   bochs.addr.bus, bochs.addr.devid, bochs.addr.function, id,
		   (unsigned long)(bochs.p.vram_size >> 10),
		   (unsigned long)bochs.bar0, (unsigned long)bochs.bar2,
		   bochs.p.nmodes, bochs.p.nmodes ? bochs.p.modes[0].name : "-");
	publish_sysfs();
	rc = kms_rows_bind(&bochs.p);
	if (rc)
		uk_pr_err("koru-os: kms: bind rows: %d\n", rc);
	return 0;
}
devfs_initcall(bochs_bind);
