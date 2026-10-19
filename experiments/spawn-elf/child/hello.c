/* Static-pie child for spawn-elf. No GPL. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

/* Gap 3: the child itself dereferences an address named by an env grant
 * (KORU_TOUCH, mode KORU_TOUCH_MODE r|w, optional KORU_SLEEP_US first).
 * Under its own CR3 an ungranted address must raise a real #PF that the
 * kernel turns into SIGSEGV; "survived" lines mean it was NOT isolated
 * (or, for the RO-read positive control, that the grant works). */
static void run_touch(int outfd)
{
	const char *t = getenv("KORU_TOUCH");
	const char *m = getenv("KORU_TOUCH_MODE");
	const char *sl = getenv("KORU_SLEEP_US");
	volatile unsigned char *p;

	if (!t)
		return;
	p = (volatile unsigned char *)strtoul(t, NULL, 0);
	if (sl) {
		usleep((useconds_t)atoi(sl));
		dprintf(outfd, "child: slept %s us\n", sl);
	}
	dprintf(outfd, "child: touch va=%p mode=%s\n", (void *)p, m ? m : "r");
	if (m && m[0] == 'w') {
		*p = 0x5a;
		dprintf(outfd, "child: touch write survived\n");
	} else {
		unsigned v = *p;

		dprintf(outfd, "child: touch read survived value=0x%02x\n", v);
	}
}

int main(int argc, char **argv)
{
	int fd, flags, nopen = 0;
	extern char **environ;
	char **e;
	int have_out;

	(void)argc; (void)argv;
	have_out = (fcntl(1, F_GETFD) >= 0);
	for (fd = 0; fd < 64; fd++) {
		flags = fcntl(fd, F_GETFD);
		if (flags < 0) continue;
		nopen++;
	}
	if (!have_out) {
		_exit(nopen);
	}
	dprintf(1, "child: begin pid=%d\n", (int)getpid());
	for (fd = 0; fd < 64; fd++) {
		flags = fcntl(fd, F_GETFD);
		if (flags < 0) continue;
		dprintf(1, "child: fd %d cloexec=%d\n", fd,
			(flags & FD_CLOEXEC) ? 1 : 0);
	}
	dprintf(1, "child: nopen=%d\n", nopen);
	if (environ) {
		for (e = environ; *e; e++)
			dprintf(1, "child: env %s\n", *e);
	}
	run_touch(1);
	if (access("/etc/passwd", R_OK) == 0)
		dprintf(1, "child: FAIL ambient /etc/passwd readable\n");
	else
		dprintf(1, "child: path /etc/passwd refused errno=%d\n", errno);
	dprintf(1, "child: hello from an external ELF\n");
	if (fcntl(2, F_GETFD) >= 0)
		dprintf(1, "child: FAIL stderr present\n");
	else
		dprintf(1, "child: stderr absent (empty by default)\n");
	dprintf(1, "child: done\n");
	return 0;
}
