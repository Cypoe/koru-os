/* Static-pie child for spawn-elf. No GPL. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

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
		/* Empty bag: no way to print; encode nopen in the exit status. */
		_exit(nopen); /* 0 = empty, as required */
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
