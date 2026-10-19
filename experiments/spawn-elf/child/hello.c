/* Static-pie child for spawn-elf. No GPL. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

#define KSP_PROBE_MAGIC 0x4B535052554C54ULL

static void run_mmu_report(int outfd)
{
	const char *rs;
	unsigned long *res;
	char *end;

	rs = getenv("KORU_PROBE_RESULT");
	if (!rs)
		return;
	res = (unsigned long *)strtoul(rs, &end, 0);
	if (!res)
		return;
	/* Ambient heap is mapped in the child PT; reading it proves child CR3. */
	if (res[3] != KSP_PROBE_MAGIC) {
		dprintf(outfd, "child: FAIL probe magic=0x%lx\n", res[3]);
		return;
	}
	if (res[0] == 1)
		dprintf(outfd, "child: parent-heap fault ok (hw under child CR3)\n");
	else
		dprintf(outfd, "child: FAIL parent-heap not isolated\n");
	if (res[1] == 0 && res[2] == 0)
		; /* no RO grant in this bag — skip */
	else if (res[1] == 1 && res[2] == 1)
		dprintf(outfd, "child: attenuation RO write fault ok (hw under child CR3)\n");
	else
		dprintf(outfd, "child: FAIL attenuation read=%lu write_fault=%lu\n",
			res[1], res[2]);
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
	run_mmu_report(1);
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
