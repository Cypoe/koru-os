/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M7: native i8042 PS/2 keyboard provider behind the input.* rows.
 *
 * The controller is put into translated mode (config bit 6), so the keyboard's
 * scan code set 2 arrives as set 1. Set 1 make codes 0x01..0x58 are the Linux
 * KEY_* numbers; 0xE0-prefixed codes go through e0_map. The IRQ 1 handler only
 * moves bytes into a ring and ups a semaphore; a koru-input thread decodes and
 * reports through input_rows_event(), so no personality code runs in IRQ context.
 * The aux (mouse) port is left disabled: M7a is keyboard only.
 */
#include <errno.h>
#include <string.h>
#include <uk/essentials.h>
#include <uk/intctlr.h>
#include <uk/init.h>
#include <uk/print.h>
#include <uk/sched.h>
#include <uk/semaphore.h>
#include <uk/lcpu.h>
#include <devfs/device.h>
#include "input_rows.h"

#define I8042_DATA	0x60
#define I8042_STATUS	0x64
#define I8042_CMD	0x64
#define ST_OBF		0x01
#define ST_IBF		0x02
#define ST_AUX		0x20
#define CFG_KBD_IRQ	0x01
#define CFG_AUX_IRQ	0x02
#define CFG_KBD_CLKOFF	0x10
#define CFG_AUX_CLKOFF	0x20
#define CFG_XLATE	0x40
#define KBD_IRQ		1

#define EV_SYN 0x00
#define EV_KEY 0x01
#define EV_MSC 0x04
#define EV_LED 0x11
#define EV_REP 0x14
#define MSC_SCAN 0x04

static inline uint8_t inb(uint16_t p)
{
	uint8_t v;

	__asm__ __volatile__("inb %1, %0" : "=a"(v) : "Nd"(p));
	return v;
}

static inline void outb(uint16_t p, uint8_t v)
{
	__asm__ __volatile__("outb %0, %1" : : "a"(v), "Nd"(p));
}

static int wait_ibf_clear(void)
{
	for (int i = 0; i < 100000; i++)
		if (!(inb(I8042_STATUS) & ST_IBF))
			return 0;
	return -ETIMEDOUT;
}

static int wait_obf(void)
{
	for (int i = 0; i < 100000; i++)
		if (inb(I8042_STATUS) & ST_OBF)
			return 0;
	return -ETIMEDOUT;
}

static void ctl_cmd(uint8_t c)
{
	wait_ibf_clear();
	outb(I8042_CMD, c);
}

static void flush_obf(void)
{
	for (int i = 0; i < 64 && (inb(I8042_STATUS) & ST_OBF); i++)
		(void)inb(I8042_DATA);
}

/* IRQ -> thread ring */
#define RING 256
static volatile uint8_t ring[RING];
static volatile unsigned int r_head, r_tail;
static struct uk_semaphore ring_sem;
static unsigned long irq_count, ring_drops;

static int kbd_irq(void *arg __unused)
{
	int got = 0;
	uint8_t st;

	while ((st = inb(I8042_STATUS)) & ST_OBF) {
		uint8_t b = inb(I8042_DATA);

		if (st & ST_AUX)
			continue;	/* aux port is disabled; drop stray bytes */
		if (r_head - r_tail < RING)
			ring[r_head++ % RING] = b;
		else
			ring_drops++;
		got = 1;
	}
	if (got) {
		irq_count++;
		uk_semaphore_up(&ring_sem);
	}
	return got;
}

/* 0xE0-prefixed set 1 codes -> Linux KEY_* (0 = ignore) */
static const uint16_t e0_map[128] = {
	[0x1c] = 96,  /* KEY_KPENTER */
	[0x1d] = 97,  /* KEY_RIGHTCTRL */
	[0x35] = 98,  /* KEY_KPSLASH */
	[0x37] = 99,  /* KEY_SYSRQ */
	[0x38] = 100, /* KEY_RIGHTALT */
	[0x47] = 102, /* KEY_HOME */
	[0x48] = 103, /* KEY_UP */
	[0x49] = 104, /* KEY_PAGEUP */
	[0x4b] = 105, /* KEY_LEFT */
	[0x4d] = 106, /* KEY_RIGHT */
	[0x4f] = 107, /* KEY_END */
	[0x50] = 108, /* KEY_DOWN */
	[0x51] = 109, /* KEY_PAGEDOWN */
	[0x52] = 110, /* KEY_INSERT */
	[0x53] = 111, /* KEY_DELETE */
	[0x5b] = 125, /* KEY_LEFTMETA */
	[0x5c] = 126, /* KEY_RIGHTMETA */
	[0x5d] = 127, /* KEY_COMPOSE */
};

static uint8_t down[96];

static void decode(uint8_t b)
{
	static int e0, e1;
	unsigned int code, kc, scan;
	int rel, val;

	if (e1) {	/* Pause: E1 1D 45 E1 9D C5, no release semantics */
		if (++e1 == 6) {
			e1 = 0;
			input_rows_event(EV_KEY, 119, 1);	/* KEY_PAUSE */
			input_rows_event(EV_SYN, 0, 0);
			input_rows_event(EV_KEY, 119, 0);
			input_rows_event(EV_SYN, 0, 0);
		}
		return;
	}
	if (b == 0xe0) { e0 = 1; return; }
	if (b == 0xe1) { e1 = 1; return; }
	/* overrun, ACK, resend, echo; 0xaa is not filtered: in set 1 it is the
	 * LeftShift break code (BAT only follows a reset, which we never send)
	 */
	if (b == 0x00 || b == 0xfa || b == 0xfe || b == 0xee || b == 0xff)
		{ e0 = 0; return; }
	code = b & 0x7f; rel = b & 0x80;
	scan = e0 ? (code | 0x80) : code;	/* as Linux atkbd reports MSC_SCAN */
	if (e0) {
		e0 = 0;
		if (code == 0x2a || code == 0x36)
			return;		/* fake shifts around E0 keys */
		kc = e0_map[code];
	} else {
		kc = (code >= 1 && code <= 0x58) ? code : 0;
	}
	if (!kc) {
		uk_pr_warn("koru-os: input.ps2: unmapped scan code 0x%x\n", scan);
		return;
	}
	if (rel)
		val = 0;
	else
		val = (down[kc / 8] & (1 << (kc % 8))) ? 2 : 1;
	if (val)
		down[kc / 8] |= 1 << (kc % 8);
	else
		down[kc / 8] &= ~(1 << (kc % 8));
	input_rows_event(EV_MSC, MSC_SCAN, (int32_t)scan);
	input_rows_event(EV_KEY, kc, val);
	input_rows_event(EV_SYN, 0, 0);
}

static __noreturn void kbd_thread(void *arg __unused)
{
	for (;;) {
		unsigned long f;
		uint8_t buf[RING];
		unsigned int n = 0;

		uk_semaphore_down(&ring_sem);
		f = uk_lcpu_save_irqf();
		while (r_tail != r_head && n < RING)
			buf[n++] = ring[r_tail++ % RING];
		uk_lcpu_restore_irqf(f);
		for (unsigned int i = 0; i < n; i++)
			decode(buf[i]);
	}
}

static struct input_provider ps2 = {
	.name = "koru-os i8042 keyboard (set 1)",
	.phys = "isa0060/serio0/input0",
	.bustype = 0x11 /* BUS_I8042 */, .vendor = 0x0001, .product = 0x0001,
	.version = 0xab41,
	.rep_delay_ms = 250, .rep_period_ms = 33,
};

static int ps2kbd_bind(struct uk_init_ctx *ictx __unused)
{
	uint8_t cfg0, cfg;
	int ack = -1, rc;

	ctl_cmd(0xad);		/* disable kbd port */
	ctl_cmd(0xa7);		/* disable aux port */
	flush_obf();
	ctl_cmd(0x20);
	if (wait_obf()) {
		uk_pr_err("koru-os: input.ps2: no i8042 controller\n");
		return 0;	/* no provider; /dev/input/event0 is not created */
	}
	cfg0 = inb(I8042_DATA);
	cfg = (cfg0 | CFG_KBD_IRQ | CFG_XLATE | CFG_AUX_CLKOFF)
	      & ~(CFG_AUX_IRQ | CFG_KBD_CLKOFF);
	ctl_cmd(0x60);
	wait_ibf_clear();
	outb(I8042_DATA, cfg);
	ctl_cmd(0xae);		/* enable kbd port */
	wait_ibf_clear();
	outb(I8042_DATA, 0xf4);	/* keyboard: enable scanning */
	if (!wait_obf())
		ack = inb(I8042_DATA);
	flush_obf();

	ps2.evbits[0] = (1 << EV_SYN) | (1 << EV_KEY) | (1 << EV_MSC);
	ps2.evbits[EV_LED / 8] |= 1 << (EV_LED % 8);
	ps2.evbits[EV_REP / 8] |= 1 << (EV_REP % 8);
	for (unsigned int k = 1; k <= 0x58; k++)
		ps2.keybits[k / 8] |= 1 << (k % 8);
	for (unsigned int i = 0; i < 128; i++)
		if (e0_map[i])
			ps2.keybits[e0_map[i] / 8] |= 1 << (e0_map[i] % 8);
	ps2.keybits[119 / 8] |= 1 << (119 % 8);
	ps2.mscbits[0] = 1 << MSC_SCAN;
	ps2.ledbits[0] = 0x07;	/* NUML, CAPSL, SCROLLL */

	uk_semaphore_init(&ring_sem, 0);
	if (!uk_sched_thread_create(uk_sched_current(), kbd_thread, NULL,
				    "koru-input")) {
		uk_pr_err("koru-os: input.ps2: cannot create thread\n");
		return -ENOMEM;
	}
	rc = uk_intctlr_irq_register(KBD_IRQ, kbd_irq, NULL);
	if (rc) {
		uk_pr_err("koru-os: input.ps2: IRQ %d register failed: %d\n",
			  KBD_IRQ, rc);
		return rc;
	}
	rc = input_rows_bind(&ps2);
	uk_pr_err("koru-os: INFO input.ps2: i8042 cfg 0x%02x -> 0x%02x, enable-scan ack 0x%02x, IRQ %d, bind %d\n",
		   cfg0, cfg, ack & 0xff, KBD_IRQ, rc);
	return rc;
}
devfs_initcall(ps2kbd_bind);

/* for the M7 evidence: printed by evdev_linux.c on last close */
unsigned long koru_ps2_irq_count(void) { return irq_count; }
unsigned long koru_ps2_ring_drops(void) { return ring_drops; }
