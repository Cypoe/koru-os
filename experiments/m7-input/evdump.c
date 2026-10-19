/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M7 evdev probe (same binary on koru-os and on the L1 Linux oracle).
 * Usage: evdump /dev/input/eventN
 * Prints the device identity and capability bits, checks O_NONBLOCK read on an
 * empty queue and EVIOCGRAB semantics, prints "evdump: READY", then poll()s and
 * read()s events until KEY_ESC is released, printing every event as
 *   evdump: ev <type> <code> <value>
 * and finally a summary line. Exit 0 if ESC release was seen.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/input.h>

static int nbits(const unsigned char *b, int n)
{
	int c = 0;

	for (int i = 0; i < n * 8; i++)
		c += !!(b[i / 8] & (1 << (i % 8)));
	return c;
}

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/dev/input/event0";
	unsigned char evb[8] = { 0 }, keyb[KEY_MAX / 8 + 1] = { 0 }, ks[KEY_MAX / 8 + 1];
	char name[256] = "", phys[256] = "";
	struct input_event ev[64];
	struct input_id id;
	unsigned int rep[2] = { 0, 0 };
	int ver = 0, fd, r, e, keys = 0, syns = 0, mscs = 0, polls = 0, done = 0;
	long long last = 0, nonmono = 0;

	setvbuf(stdout, NULL, _IOLBF, 0);
	fd = open(path, O_RDONLY | O_NONBLOCK);
	if (fd < 0) { printf("evdump: open %s nonblock: errno %d\n", path, errno); return 2; }
	r = read(fd, ev, sizeof(ev)); e = errno;
	printf("evdump: nonblock read on empty queue: %d errno %d (%s)\n", r, r < 0 ? e : 0,
	       r < 0 && e == EAGAIN ? "EAGAIN, ok" : "UNEXPECTED");
	close(fd);

	fd = open(path, O_RDONLY);
	if (fd < 0) { printf("evdump: open %s: errno %d\n", path, errno); return 2; }
	r = ioctl(fd, EVIOCGVERSION, &ver);
	printf("evdump: EVIOCGVERSION rc %d version 0x%06x\n", r < 0 ? -errno : 0, ver);
	r = ioctl(fd, EVIOCGID, &id);
	printf("evdump: EVIOCGID rc %d bus 0x%04x vendor 0x%04x product 0x%04x version 0x%04x\n",
	       r < 0 ? -errno : 0, id.bustype, id.vendor, id.product, id.version);
	r = ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name);
	printf("evdump: EVIOCGNAME rc %s name \"%s\"\n", r < 0 ? "<0" : ">=0", name);
	r = ioctl(fd, EVIOCGPHYS(sizeof(phys) - 1), phys);
	printf("evdump: EVIOCGPHYS rc %s phys \"%s\"\n", r < 0 ? "<0" : ">=0", phys);
	r = ioctl(fd, EVIOCGBIT(0, sizeof(evb)), evb);
	printf("evdump: EV bits:%s%s%s%s%s%s%s\n", evb[0] & (1 << EV_SYN) ? " SYN" : "",
	       evb[0] & (1 << EV_KEY) ? " KEY" : "", evb[0] & (1 << EV_REL) ? " REL" : "",
	       evb[0] & (1 << EV_ABS) ? " ABS" : "", evb[0] & (1 << EV_MSC) ? " MSC" : "",
	       evb[EV_LED / 8] & (1 << (EV_LED % 8)) ? " LED" : "",
	       evb[EV_REP / 8] & (1 << (EV_REP % 8)) ? " REP" : "");
	r = ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keyb)), keyb);
	printf("evdump: KEY bits: %d set; KEY_A %d KEY_ENTER %d KEY_UP %d KEY_ESC %d KEY_LEFTSHIFT %d\n",
	       nbits(keyb, sizeof(keyb)), !!(keyb[KEY_A / 8] & (1 << (KEY_A % 8))),
	       !!(keyb[KEY_ENTER / 8] & (1 << (KEY_ENTER % 8))),
	       !!(keyb[KEY_UP / 8] & (1 << (KEY_UP % 8))), !!(keyb[KEY_ESC / 8] & (1 << (KEY_ESC % 8))),
	       !!(keyb[KEY_LEFTSHIFT / 8] & (1 << (KEY_LEFTSHIFT % 8))));
	r = ioctl(fd, EVIOCGREP, rep);
	printf("evdump: EVIOCGREP rc %d delay %u period %u\n", r < 0 ? -errno : 0, rep[0], rep[1]);
	memset(ks, 0xff, sizeof(ks));
	r = ioctl(fd, EVIOCGKEY(sizeof(ks)), ks);
	printf("evdump: EVIOCGKEY rc %s keys down %d\n", r < 0 ? "<0" : ">=0", nbits(ks, sizeof(ks)));
	r = ioctl(fd, EVIOCGRAB, (void *)1); e = errno;
	printf("evdump: EVIOCGRAB 1: %d", r < 0 ? -e : 0);
	r = ioctl(fd, EVIOCGRAB, (void *)1); e = errno;
	printf(", again: %d", r < 0 ? -e : 0);
	r = ioctl(fd, EVIOCGRAB, (void *)0); e = errno;
	printf(", 0: %d", r < 0 ? -e : 0);
	r = ioctl(fd, EVIOCGRAB, (void *)0); e = errno;
	printf(", 0 again: %d\n", r < 0 ? -e : 0);

	printf("evdump: READY\n");
	while (!done) {
		struct pollfd p = { .fd = fd, .events = POLLIN };

		r = poll(&p, 1, 60000);
		if (r <= 0) { printf("evdump: poll rc %d errno %d (timeout or error)\n", r, errno); break; }
		polls++;
		r = read(fd, ev, sizeof(ev));
		if (r < 0) { printf("evdump: read errno %d\n", errno); break; }
		if (r % sizeof(ev[0])) { printf("evdump: short read %d\n", r); break; }
		for (int i = 0; i < r / (int)sizeof(ev[0]); i++) {
			long long t = ev[i].input_event_sec * 1000000LL + ev[i].input_event_usec;

			if (t < last) nonmono++;
			last = t;
			printf("evdump: ev %u %u %d\n", ev[i].type, ev[i].code, ev[i].value);
			if (ev[i].type == EV_KEY) keys++;
			else if (ev[i].type == EV_SYN) syns++;
			else if (ev[i].type == EV_MSC) mscs++;
			if (ev[i].type == EV_KEY && ev[i].code == KEY_ESC && ev[i].value == 0) done = 1;
		}
	}
	printf("evdump: DONE keys %d syns %d msc %d polls %d nonmonotonic %lld esc %s\n",
	       keys, syns, mscs, polls, nonmono, done ? "yes" : "no");
	close(fd);
	return done ? 0 : 1;
}
