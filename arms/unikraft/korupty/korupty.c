/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M9: one pseudo-terminal pair, /dev/korupty0 (master) and /dev/korupty0s (slave).
 *
 * Unikraft 0.21 has no ptys. foot normally creates one with posix_openpt() and fork()s its
 * shell onto the slave; koru-os has no fork() (one address space), so M9 runs the shell from
 * the init script on /dev/korupty0s and starts unmodified foot with its documented option
 * `--pty=/dev/korupty0` ("display an existing pty instead of creating one").
 *
 * The line discipline is the part of Linux n_tty a shell and a terminal need: termios via
 * TCGETS/TCSETS*, ICRNL on input, OPOST|ONLCR on output, canonical mode with ECHO, VERASE,
 * VKILL and VEOF, and non-canonical (raw) mode for line editors; window size via
 * TIOCGWINSZ/TIOCSWINSZ. Not served: job control signals (ISIG characters are echoed and
 * passed on, no SIGINT is raised), flow control, packet mode, multiple pairs. Other tty
 * ioctls are refused loudly:  koru-os: REFUSED linux.ioctl.0x... (pty)
 * Hangup: with the master closed the slave reads EOF; with the slave closed the master
 * reads EIO, as on Linux.
 */
#include <errno.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <uk/print.h>
#include <uk/init.h>
#include <uk/list.h>
#include <uk/wait.h>
#include <uk/essentials.h>
#include <devfs/device.h>
#include <vfscore/uio.h>
#include <vfscore/eventpoll.h>
#include <sys/epoll.h>

long uk_syscall_r_getpgid(long);

#define RB 65536
struct ring { unsigned char b[RB]; unsigned h, t; };
static inline unsigned r_len(struct ring *r) { return r->h - r->t; }
static inline int r_put(struct ring *r, unsigned char c)
{
	if (r_len(r) >= RB)
		return 0;
	r->b[r->h++ % RB] = c;
	return 1;
}

struct kterm { uint32_t iflag, oflag, cflag, lflag; uint8_t line, cc[19]; };
struct kwinsz { uint16_t row, col, xpix, ypix; };
#define ICRNL 0x100
#define IXON 0x400
#define OPOST 0x1
#define ONLCR 0x4
#define ISIG 0x1
#define ICANON 0x2
#define ECHO 0x8
#define ECHOE 0x10
#define ECHOK 0x20
#define ECHOCTL 0x200
#define ECHOKE 0x800
#define IEXTEN 0x8000
#define VERASE 2
#define VKILL 3
#define VEOF 4

static struct {
	struct device *m, *s;
	struct ring m2s;	/* bytes the slave can read (after the ldisc) */
	struct ring s2m;	/* bytes the master can read */
	unsigned char line[4096];	/* canonical-mode edit buffer */
	unsigned ll;
	unsigned eofs;		/* pending VEOF marks: a read returns 0 at one */
	struct kterm t;
	struct kwinsz ws;
	int mopen, sopen, s_was_open;
	int fg;	/* foreground process group, 0 = not set */
	struct uk_waitq wq;
	struct uk_list_head mecb, secb;
} P;

static void wake(struct uk_list_head *l)
{
	struct uk_list_head *it;

	uk_waitq_wake_up(&P.wq);
	uk_list_for_each(it, l)
		eventpoll_signal(uk_list_entry(it, struct eventpoll_cb, cb_link),
				 EPOLLIN | EPOLLRDNORM);
}

/* slave output processing */
static void out_byte(unsigned char c)
{
	if ((P.t.oflag & OPOST) && (P.t.oflag & ONLCR) && c == '\n')
		r_put(&P.s2m, '\r');
	r_put(&P.s2m, c);
}

static void echo_byte(unsigned char c)
{
	if (!(P.t.lflag & ECHO))
		return;
	if ((P.t.lflag & ECHOCTL) && c < 0x20 && c != '\n' && c != '\t') {
		out_byte('^');
		out_byte(c + 0x40);
		return;
	}
	out_byte(c);
}

/* master input processing (n_tty receive) */
static void in_byte(unsigned char c)
{
	if ((P.t.iflag & ICRNL) && c == '\r')
		c = '\n';
	if (!(P.t.lflag & ICANON)) {
		r_put(&P.m2s, c);
		echo_byte(c);
		return;
	}
	if (c == P.t.cc[VERASE] || c == '\b') {
		if (P.ll) {
			P.ll--;
			if ((P.t.lflag & ECHO) && (P.t.lflag & ECHOE)) {
				out_byte('\b'); out_byte(' '); out_byte('\b');
			}
		}
		return;
	}
	if (c == P.t.cc[VKILL]) {
		while (P.ll) {
			P.ll--;
			if ((P.t.lflag & ECHO) && (P.t.lflag & ECHOKE)) {
				out_byte('\b'); out_byte(' '); out_byte('\b');
			}
		}
		return;
	}
	if (c == P.t.cc[VEOF]) {
		for (unsigned i = 0; i < P.ll; i++)
			r_put(&P.m2s, P.line[i]);
		if (!P.ll)
			P.eofs++;
		P.ll = 0;
		return;
	}
	if (P.ll < sizeof(P.line))
		P.line[P.ll++] = c;
	echo_byte(c);
	if (c == '\n') {
		for (unsigned i = 0; i < P.ll; i++)
			r_put(&P.m2s, P.line[i]);
		P.ll = 0;
	}
}

static int rd(struct ring *r, struct uio *uio, int ioflags, int is_slave)
{
	while (!r_len(r)) {
		if (is_slave && (P.eofs || !P.mopen)) {
			if (P.eofs)
				P.eofs--;
			return 0; /* EOF */
		}
		if (!is_slave && !P.sopen && P.s_was_open)
			return EIO;
		if (ioflags & O_NONBLOCK)
			return EAGAIN;
		uk_waitq_wait_event(&P.wq, r_len(r) || (is_slave && (P.eofs || !P.mopen))
				    || (!is_slave && !P.sopen && P.s_was_open));
	}
	while (r_len(r) && uio->uio_resid > 0) {
		unsigned char c = r->b[r->t % RB];
		int rc = vfscore_uiomove(&c, 1, uio);

		if (rc)
			return rc;
		r->t++;
		/* canonical: one line per read */
		if (is_slave && (P.t.lflag & ICANON) && c == '\n')
			break;
	}
	return 0;
}

static int wr(struct uio *uio, int is_slave)
{
	unsigned char buf[256];

	while (uio->uio_resid > 0) {
		size_t n = uio->uio_resid < (ssize_t)sizeof(buf) ? (size_t)uio->uio_resid
							      : sizeof(buf);
		int rc = vfscore_uiomove(buf, n, uio);

		if (rc)
			return rc;
		for (size_t i = 0; i < n; i++)
			is_slave ? out_byte(buf[i]) : in_byte(buf[i]);
	}
	wake(&P.mecb);
	wake(&P.secb);
	return 0;
}

static int m_read(struct device *d __unused, struct uio *u, int f) { return rd(&P.s2m, u, f, 0); }
static int s_read(struct device *d __unused, struct uio *u, int f) { return rd(&P.m2s, u, f, 1); }
static int m_write(struct device *d __unused, struct uio *u, int f __unused) { return wr(u, 0); }
static int s_write(struct device *d __unused, struct uio *u, int f __unused) { return wr(u, 1); }

static int pty_ioctl(int is_slave, unsigned long cmd, void *arg)
{
	switch (cmd) {
	case 0x5401: /* TCGETS */
		memcpy(arg, &P.t, sizeof(P.t));
		return 0;
	case 0x5402: case 0x5403: case 0x5404: /* TCSETS, TCSETSW, TCSETSF */
		memcpy(&P.t, arg, sizeof(P.t));
		if (!(P.t.lflag & ICANON) && P.ll) { /* flush the edit line */
			for (unsigned i = 0; i < P.ll; i++)
				r_put(&P.m2s, P.line[i]);
			P.ll = 0;
		}
		if (cmd == 0x5404)
			P.m2s.t = P.m2s.h;
		return 0;
	case 0x5413: /* TIOCGWINSZ */
		memcpy(arg, &P.ws, sizeof(P.ws));
		return 0;
	case 0x5414: /* TIOCSWINSZ (no SIGWINCH: no signals to a process group) */
		memcpy(&P.ws, arg, sizeof(P.ws));
		return 0;
	case 0x541B: /* FIONREAD */
		*(int *)arg = (int)r_len(is_slave ? &P.m2s : &P.s2m);
		return 0;
	case 0x540B: /* TCFLSH */
		if ((long)arg == 0 || (long)arg == 2)
			P.m2s.t = P.m2s.h;
		if ((long)arg == 1 || (long)arg == 2)
			P.s2m.t = P.s2m.h;
		return 0;
	case 0x540A: /* TCXONC */
	case 0x5409: /* TCSBRK (tcdrain): output is never held */
	case 0x540E: /* TIOCSCTTY */
	case 0x5422: /* TIOCNOTTY */
	case 0x40045431: /* TIOCSPTLCK */
	case 0x5421: /* FIONBIO: vfscore's F_SETFL O_NONBLOCK; rd() reads the file flags */
	case 0x5452: /* FIOASYNC */
		return 0;
	case 0x5410: /* TIOCSPGRP: the foreground process group */
		P.fg = *(int *)arg;
		return 0;
	case 0x540F: /* TIOCGPGRP */
	case 0x5429: /* TIOCGSID */
		/* Until a TIOCSPGRP, the caller's group is the foreground one:
		 * an interactive shell that finds itself in the background loops on
		 * kill(SIGTTIN), which queues a signal per call here */
		*(int *)arg = P.fg ? P.fg : (int)uk_syscall_r_getpgid(0);
		return 0;
	case 0x80045430: /* TIOCGPTN */
		*(unsigned *)arg = 0;
		return 0;
	default:
		uk_pr_err("koru-os: REFUSED linux.ioctl.0x%lx (pty)\n", cmd);
		return ENOTTY;
	}
}
static int m_ioctl(struct device *d __unused, unsigned long c, void *a) { return pty_ioctl(0, c, a); }
static int s_ioctl(struct device *d __unused, unsigned long c, void *a) { return pty_ioctl(1, c, a); }

static void ecb_unreg(struct eventpoll_cb *ecb) { uk_list_del(&ecb->cb_link); }

static int m_poll(struct device *d __unused, unsigned int *rev, struct eventpoll_cb *ecb)
{
	*rev = EPOLLOUT | EPOLLWRNORM
	       | (r_len(&P.s2m) ? EPOLLIN | EPOLLRDNORM : 0)
	       | (!P.sopen && P.s_was_open ? EPOLLHUP : 0);
	if (ecb && !ecb->unregister) {
		ecb->unregister = ecb_unreg;
		uk_list_add_tail(&ecb->cb_link, &P.mecb);
	}
	return 0;
}

static int s_poll(struct device *d __unused, unsigned int *rev, struct eventpoll_cb *ecb)
{
	int canon_ready = r_len(&P.m2s) || P.eofs;

	*rev = EPOLLOUT | EPOLLWRNORM | (canon_ready ? EPOLLIN | EPOLLRDNORM : 0)
	       | (!P.mopen ? EPOLLHUP : 0);
	if (ecb && !ecb->unregister) {
		ecb->unregister = ecb_unreg;
		uk_list_add_tail(&ecb->cb_link, &P.secb);
	}
	return 0;
}

static int m_open(struct device *d __unused, int f __unused) { P.mopen++; return 0; }
static int s_open(struct device *d __unused, int f __unused) { P.sopen++; P.s_was_open = 1; return 0; }
static int m_close(struct device *d __unused)
{
	if (P.mopen && !--P.mopen)
		wake(&P.secb);
	return 0;
}
static int s_close(struct device *d __unused)
{
	if (P.sopen && !--P.sopen)
		wake(&P.mecb);
	return 0;
}

static struct devops m_ops = { .open = m_open, .close = m_close, .read = m_read,
	.write = m_write, .ioctl = m_ioctl, .poll = m_poll };
static struct devops s_ops = { .open = s_open, .close = s_close, .read = s_read,
	.write = s_write, .ioctl = s_ioctl, .poll = s_poll };
static struct driver m_drv = { .devops = &m_ops, .devsz = 0, .name = "korupty-master" };
static struct driver s_drv = { .devops = &s_ops, .devsz = 0, .name = "korupty-slave" };

static int pty_init(struct uk_init_ctx *ictx __unused)
{
	static const uint8_t cc[19] = { 3, 28, 127, 21, 4, 0, 1, 0, 17, 19, 26, 0, 18, 15, 23, 22 };

	P.t = (struct kterm){ ICRNL | IXON, OPOST | ONLCR, 0xbf,
			      ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | IEXTEN, 0, {0} };
	memcpy(P.t.cc, cc, sizeof(cc));
	P.ws = (struct kwinsz){ 24, 80, 0, 0 };
	uk_waitq_init(&P.wq);
	UK_INIT_LIST_HEAD(&P.mecb);
	UK_INIT_LIST_HEAD(&P.secb);
	if (device_create(&m_drv, "korupty0", D_CHR, &P.m)
	    || device_create(&s_drv, "korupty0s", D_CHR, &P.s))
		uk_pr_err("koru-os: korupty: device_create failed\n");
	else {
		P.m->rdev = (5 << 8) | 2;		/* like /dev/ptmx (5:2) */
		P.s->rdev = (136 << 8) | 0;	/* like /dev/pts/0 (136:0) */
	}
	return 0;
}
uk_late_initcall(pty_init, 0);
