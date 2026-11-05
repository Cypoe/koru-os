/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M7: Linux evdev personality on /dev/input/event0 (char 13:64), fed by
 * the input.* rows (input_rows.h). Implements the uAPI subset evtest and
 * libevdev use: version/id/name/phys/uniq/prop, EVIOCGBIT for every type,
 * EVIOCGKEY/LED/SND/SW state, EVIOCGREP/SREP, EVIOCGRAB, EVIOCSCLOCKID, read()
 * of struct input_event (blocking and O_NONBLOCK) and poll/select/epoll
 * readiness (patch unikraft-0.21-devfs-poll-nonblock). Anything else is
 * refused with the errno Linux evdev returns for a device without that
 * feature and logged as
 *   koru-os: REFUSED linux.ioctl.EVIOC<name> (evdev)
 * Ioctls return 0 on success where Linux returns a byte count (observation in
 * the M7 README; evtest and libevdev only test for < 0).
 * One event queue shared by all open files (one reader at a time in M7a);
 * events are dropped while nobody has the device open, as on Linux.
 */
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <stdio.h>
#include <time.h>
#include <sys/epoll.h>
#include <sys/sysmacros.h>
#include <uk/essentials.h>
#include <uk/list.h>
#include <uk/print.h>
#include <uk/wait.h>
#include <uk/plat/time.h>
#include <devfs/device.h>
#include <vfscore/uio.h>
#include <vfscore/eventpoll.h>
#include "input_rows.h"
#include "korusysfs.h"

struct kinput_event {	/* struct input_event, x86_64 */
	int64_t sec, usec;
	uint16_t type, code;
	int32_t value;
};
_Static_assert(sizeof(struct kinput_event) == 24, "input_event size");

#define QLEN 512
static struct {
	struct input_provider *p;
	struct device *dev;
	struct kinput_event q[QLEN];
	unsigned int head, tail;	/* tail: next to read */
	unsigned long drops, queued, readn;
	int opens, grabbed, clk;
	uint8_t keystate[96], ledstate[2];
	struct uk_waitq wq;
	struct uk_list_head ecbs;
} E;

static unsigned int qcount(void) { return E.head - E.tail; }

static void ecb_unregister(struct eventpoll_cb *ecb)
{
	uk_list_del(&ecb->cb_link);
}

void input_rows_event(uint16_t type, uint16_t code, int32_t value)
{
	__nsec t;
	struct kinput_event *e;
	struct uk_list_head *it;

	if (!E.p)
		return;
	if (type == 0x01 && code < 96 * 8) {
		if (value)
			E.keystate[code / 8] |= 1 << (code % 8);
		else
			E.keystate[code / 8] &= ~(1 << (code % 8));
	}
	if (!E.opens)
		return;
	if (qcount() >= QLEN) {
		E.drops++;
		return;
	}
	/* plat clocks, not clock_gettime(): this runs in the koru-input
	 * kernel thread, which has no posix-process context
	 */
	t = E.clk == CLOCK_REALTIME ? ukplat_wall_clock() : ukplat_monotonic_clock();
	e = &E.q[E.head % QLEN];
	e->sec = t / 1000000000ULL; e->usec = (t % 1000000000ULL) / 1000;
	e->type = type; e->code = code; e->value = value;
	E.head++; E.queued++;
	if (type != 0x00)	/* wake readers once per packet (on EV_SYN) */
		return;
	uk_waitq_wake_up(&E.wq);
	uk_list_for_each(it, &E.ecbs) {
		struct eventpoll_cb *ecb = uk_list_entry(it, struct eventpoll_cb,
							 cb_link);
		eventpoll_signal(ecb, EPOLLIN | EPOLLRDNORM);
	}
}

/* readiness: complete packets only (queue ends with EV_SYN after a wake) */
static int ev_ready(void)
{
	return qcount() && E.q[(E.head - 1) % QLEN].type == 0x00;
}

static int ev_read(struct device *dev __unused, struct uio *uio, int ioflags)
{
	int rc;

	if (uio->uio_resid < (ssize_t)sizeof(struct kinput_event))
		return EINVAL;
	if (!ev_ready()) {
		if (ioflags & O_NONBLOCK)
			return EAGAIN;
		uk_waitq_wait_event(&E.wq, ev_ready());
	}
	while (qcount() && uio->uio_resid >= (ssize_t)sizeof(struct kinput_event)) {
		rc = vfscore_uiomove(&E.q[E.tail % QLEN], sizeof(struct kinput_event),
				     uio);
		if (rc)
			return rc;
		E.tail++; E.readn++;
	}
	return 0;
}

static int ev_poll(struct device *dev __unused, unsigned int *revents,
		   struct eventpoll_cb *ecb)
{
	*revents = ev_ready() ? (EPOLLIN | EPOLLRDNORM) : 0;
	if (ecb && !ecb->unregister) {
		ecb->unregister = ecb_unregister;
		uk_list_add_tail(&ecb->cb_link, &E.ecbs);
	}
	return 0;
}

static int refuse(unsigned long cmd, int err)
{
	unsigned int nr = cmd & 0xff;
	const char *n = NULL;

	if (((cmd >> 8) & 0xff) != 'E') {
		uk_pr_err("koru-os: REFUSED linux.ioctl.0x%lx (evdev)\n", cmd);
		return ENOTTY;
	}
	switch (nr) {
	case 0x04: n = "EVIOCGKEYCODE"; break;
	case 0x05: n = "EVIOCGKEYCODE_V2"; break;
	case 0x0a: n = "EVIOCGMTSLOTS"; break;
	case 0x80: n = "EVIOCSFF"; break;
	case 0x81: n = "EVIOCRMFF"; break;
	case 0x84: n = "EVIOCGEFFECTS"; break;
	case 0x91: n = "EVIOCREVOKE"; break;
	case 0x92: n = "EVIOCGMASK"; break;
	case 0x93: n = "EVIOCSMASK"; break;
	}
	if ((nr >= 0x40 && nr < 0x80) || nr >= 0xc0)
		uk_pr_err("koru-os: REFUSED linux.ioctl.EVIOC%cABS(0x%02x) (evdev, no EV_ABS)\n",
			  nr >= 0xc0 ? 'S' : 'G', nr & 0x3f);
	else if (n)
		uk_pr_err("koru-os: REFUSED linux.ioctl.%s (evdev)\n", n);
	else
		uk_pr_err("koru-os: REFUSED linux.ioctl.EVIOC_nr_0x%02x (evdev)\n",
			  nr);
	return err;
}

static int put_bits(void *arg, size_t len, const void *bits, size_t blen)
{
	/* Linux copies min(len, bitmap size rounded to longs) and zero-fills
	 * nothing else; our bitmaps are already long-rounded by the caller.
	 */
	memset(arg, 0, len);
	memcpy(arg, bits, len < blen ? len : blen);
	return 0;
}

static int put_str(void *arg, size_t len, const char *s)
{
	size_t n;

	if (!s)
		return ENOENT;
	n = strlen(s) + 1;
	if (len) {
		memcpy(arg, s, n < len ? n : len);
		((char *)arg)[(n < len ? n : len) - 1] = '\0';
	}
	return 0;
}

static int ev_ioctl(struct device *dev __unused, unsigned long cmd, void *arg)
{
	static const uint8_t zero[96];
	unsigned int dir = (cmd >> 30) & 3, nr = cmd & 0xff;
	size_t len = (cmd >> 16) & 0x3fff;
	struct input_provider *p = E.p;
	uint8_t evb[8] = { 0 }, keyb[96] = { 0 }, mscb[8] = { 0 }, ledb[8] = { 0 };

	if (((cmd >> 8) & 0xff) != 'E')
		return refuse(cmd, ENOTTY);
	memcpy(evb, p->evbits, sizeof(p->evbits));
	memcpy(keyb, p->keybits, sizeof(p->keybits));
	memcpy(mscb, p->mscbits, sizeof(p->mscbits));
	memcpy(ledb, p->ledbits, sizeof(p->ledbits));

	if (dir == 2 /* _IOC_READ */) {
		switch (nr) {
		case 0x01: *(int *)arg = 0x010001; return 0;	/* EVIOCGVERSION */
		case 0x02: {					/* EVIOCGID */
			uint16_t *id = arg;

			id[0] = p->bustype; id[1] = p->vendor;
			id[2] = p->product; id[3] = p->version;
			return 0;
		}
		case 0x03: {					/* EVIOCGREP */
			unsigned int *r = arg;

			r[0] = p->rep_delay_ms; r[1] = p->rep_period_ms;
			return 0;
		}
		case 0x06: return put_str(arg, len, p->name);	/* EVIOCGNAME */
		case 0x07: return put_str(arg, len, p->phys);	/* EVIOCGPHYS */
		case 0x08: return put_str(arg, len, NULL);	/* EVIOCGUNIQ */
		case 0x09: return put_bits(arg, len, zero, 8);	/* EVIOCGPROP */
		case 0x18: return put_bits(arg, len, E.keystate, 96); /* EVIOCGKEY */
		case 0x19: return put_bits(arg, len, E.ledstate, 8);  /* EVIOCGLED */
		case 0x1a: return put_bits(arg, len, zero, 8);	/* EVIOCGSND */
		case 0x1b: return put_bits(arg, len, zero, 8);	/* EVIOCGSW */
		}
		if (nr >= 0x20 && nr < 0x40) {			/* EVIOCGBIT */
			switch (nr - 0x20) {
			case 0x00: return put_bits(arg, len, evb, 8);
			case 0x01: return put_bits(arg, len, keyb, 96);
			case 0x02: case 0x03: case 0x05: case 0x12: case 0x15:
				return put_bits(arg, len, zero,
						(nr - 0x20) == 0x15 ? 16 : 8);
			case 0x04: return put_bits(arg, len, mscb, 8);
			case 0x11: return put_bits(arg, len, ledb, 8);
			case 0x14: return put_bits(arg, len, zero, 8); /* EV_REP: no bits */
			}
			return EINVAL;
		}
	}
	if (dir == 1 /* _IOC_WRITE */) {
		switch (nr) {
		case 0x03: return 0;				/* EVIOCSREP */
		case 0x90:					/* EVIOCGRAB */
			if ((intptr_t)arg) {
				if (E.grabbed)
					return EBUSY;
				E.grabbed = 1;
			} else {
				if (!E.grabbed)
					return EINVAL;
				E.grabbed = 0;
			}
			return 0;
		case 0xa0: {					/* EVIOCSCLOCKID */
			int c = *(int *)arg;

			if (c != CLOCK_REALTIME && c != CLOCK_MONOTONIC
			    && c != CLOCK_BOOTTIME)
				return EINVAL;
			E.clk = c;
			E.head = E.tail;	/* Linux flushes the client queue */
			return 0;
		}
		}
	}
	return refuse(cmd, EINVAL);
}

unsigned long koru_ps2_irq_count(void);
unsigned long koru_ps2_ring_drops(void);

static int ev_open(struct device *dev __unused, int mode __unused)
{
	if (!E.opens++) {
		E.head = E.tail = 0;
		E.clk = CLOCK_REALTIME;
	}
	return 0;
}

static int ev_close(struct device *dev __unused)
{
	if (E.opens && !--E.opens) {
		E.grabbed = 0;
		uk_pr_err("koru-os: INFO input rows: event0 closed: %lu events queued, %lu read, %lu dropped; i8042 %lu IRQs, %lu ring drops\n",
			   E.queued, E.readn, E.drops, koru_ps2_irq_count(),
			   koru_ps2_ring_drops());
	}
	return 0;
}

static struct devops ev_devops = {
	.open = ev_open,
	.close = ev_close,
	.read = ev_read,
	.write = (devop_write_t)devop_eperm,
	.ioctl = ev_ioctl,
	.poll = ev_poll,
};

static struct driver ev_drv = {
	.devops = &ev_devops,
	.devsz = 0,
	.name = "koruinput",
};

/*
 * M7b sysfs view: <provider parent>/input/input0 and .../input0/event0 with the
 * uevent and attributes Linux's input core writes (input_dev_uevent,
 * input_print_bitmap, input_print_modalias), from the provider's bitmaps.
 */
static size_t bm_print(char *b, size_t n, const uint8_t *bits, size_t nbytes)
{
	size_t nw = (nbytes + 7) / 8, o = 0;
	int w, started = 0;

	for (w = (int)nw - 1; w >= 0; w--) {
		uint64_t v = 0;

		for (int i = 7; i >= 0; i--)
			if ((size_t)(w * 8 + i) < nbytes)
				v = (v << 8) | bits[w * 8 + i];
			else
				v <<= 8;
		if (!v && !started && w)
			continue;
		o += snprintf(b + o, n - o, started ? " %lx" : "%lx", (unsigned long)v);
		started = 1;
	}
	return o;
}

static size_t ma_print(char *b, size_t n, char c, const uint8_t *bits,
		       size_t nbytes, unsigned int min)
{
	size_t o = snprintf(b, n, "%c", c);

	for (unsigned int i = min; bits && i < nbytes * 8; i++)
		if (bits[i / 8] & (1 << (i % 8)))
			o += snprintf(b + o, n - o, "%X,", i);
	return o;
}

static void publish_sysfs(struct input_provider *p)
{
	static char ue[2048], ma[1024], d[160], f[200], v[200], ev[64], key[256],
		    msc[32], led[32];
	const char *par = p->sys_parent ? p->sys_parent : "virtual";
	size_t o;

	bm_print(ev, sizeof(ev), p->evbits, sizeof(p->evbits));
	bm_print(key, sizeof(key), p->keybits, sizeof(p->keybits));
	bm_print(msc, sizeof(msc), p->mscbits, sizeof(p->mscbits));
	bm_print(led, sizeof(led), p->ledbits, sizeof(p->ledbits));
	o = snprintf(ma, sizeof(ma), "input:b%04Xv%04Xp%04Xe%04X-",
		     p->bustype, p->vendor, p->product, p->version);
	o += ma_print(ma + o, sizeof(ma) - o, 'e', p->evbits, sizeof(p->evbits), 0);
	o += ma_print(ma + o, sizeof(ma) - o, 'k', p->keybits, sizeof(p->keybits), 0x71);
	o += ma_print(ma + o, sizeof(ma) - o, 'r', NULL, 0, 0);
	o += ma_print(ma + o, sizeof(ma) - o, 'a', NULL, 0, 0);
	o += ma_print(ma + o, sizeof(ma) - o, 'm', p->mscbits, sizeof(p->mscbits), 0);
	o += ma_print(ma + o, sizeof(ma) - o, 'l', p->ledbits, sizeof(p->ledbits), 0);
	snprintf(ma + o, sizeof(ma) - o, "sfw");
	snprintf(ue, sizeof(ue),
		 "PRODUCT=%x/%x/%x/%x\nNAME=\"%s\"\nPHYS=\"%s\"\nPROP=0\nEV=%s\n"
		 "KEY=%s\nMSC=%s\nLED=%s\nMODALIAS=%s\n",
		 p->bustype, p->vendor, p->product, p->version, p->name,
		 p->phys ? p->phys : "", ev, key, msc, led, ma);
	snprintf(d, sizeof(d), "%s/input/input0", par);
	korusysfs_device(d, "class/input", ue, NULL);
#define ATTR(name, fmt, ...) do { \
	snprintf(f, sizeof(f), "devices/%s/" name, d); \
	snprintf(v, sizeof(v), fmt, __VA_ARGS__); korusysfs_file(f, v); } while (0)
	snprintf(f, sizeof(f), "devices/%s/name", d);
	snprintf(ue, sizeof(ue), "%s\n", p->name); korusysfs_file(f, ue);
	ATTR("phys", "%s\n", p->phys ? p->phys : "");
	ATTR("properties", "%s\n", "0");
	snprintf(f, sizeof(f), "devices/%s/modalias", d);
	snprintf(ue, sizeof(ue), "%s\n", ma); korusysfs_file(f, ue);
	ATTR("id/bustype", "%04x\n", p->bustype);
	ATTR("id/vendor", "%04x\n", p->vendor);
	ATTR("id/product", "%04x\n", p->product);
	ATTR("id/version", "%04x\n", p->version);
	ATTR("capabilities/ev", "%s\n", ev);
	ATTR("capabilities/msc", "%s\n", msc);
	ATTR("capabilities/led", "%s\n", led);
	ATTR("capabilities/rel", "%s\n", "0");
	ATTR("capabilities/abs", "%s\n", "0");
	snprintf(f, sizeof(f), "devices/%s/capabilities/key", d);
	snprintf(ue, sizeof(ue), "%s\n", key); korusysfs_file(f, ue);
#undef ATTR
	snprintf(f, sizeof(f), "%s/event0", d);
	korusysfs_device(f, "class/input",
			 "MAJOR=13\nMINOR=64\nDEVNAME=input/event0\n", "13:64");
	snprintf(f, sizeof(f), "devices/%s/event0/device", d);
	snprintf(v, sizeof(v), "devices/%s", d);
	korusysfs_link(f, v);
}

int input_rows_bind(struct input_provider *p)
{
	int rc;

	if (E.p)
		return -EBUSY;
	uk_waitq_init(&E.wq);
	UK_INIT_LIST_HEAD(&E.ecbs);
	rc = device_create(&ev_drv, "input/event0", D_CHR, &E.dev);
	if (rc)
		return -rc;
	E.dev->rdev = makedev(13, 64);
	E.p = p;
	publish_sysfs(p);
	uk_pr_err("koru-os: INFO input rows bound: /dev/input/event0 -> %s\n",
		   p->name);
	return 0;
}
