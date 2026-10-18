#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>
static int run(const char *name, int mode) {
	int p[2] = {-1, -1};
	if (mode == 2 && pipe(p) < 0) { perror("pipe"); return 1; }
	pid_t pid = vfork();
	if (pid < 0) { perror("vfork"); return 1; }
	if (pid == 0) {
		if (mode == 1) { int fd = open("/tmp/out", O_WRONLY|O_CREAT|O_TRUNC, 0644); if (fd < 0) _exit(90); if (dup2(fd, 1) < 0) _exit(91); close(fd); }
		if (mode == 2) { if (dup2(p[1], 1) < 0) _exit(92); close(p[0]); close(p[1]); }
		if (mode == 3) { close(5); }
		char *av[] = {"/bin/busybox", "echo", "child-ok", NULL};
		execv(av[0], av); _exit(127);
	}
	if (mode == 2) { close(p[1]); char b[64] = {0}; ssize_t n = read(p[0], b, sizeof b - 1); printf("[%s] parent read %zd: %s", name, n, b); close(p[0]); }
	int st = 0; pid_t w = waitpid(pid, &st, 0);
	printf("[%s] waitpid=%d exited=%d status=%d\n", name, (int)w, WIFEXITED(st), WEXITSTATUS(st));
	if (mode == 1) { char b[64] = {0}; int fd = open("/tmp/out", O_RDONLY); read(fd, b, 63); printf("[%s] file: %s", name, b); close(fd); }
	fflush(stdout); return 0;
}
int main(int argc, char **argv) {
	int m = argc > 1 ? atoi(argv[1]) : 0;
	const char *names[] = {"plain", "redirect", "pipe", "close"};
	printf("vrepro mode %d\n", m); fflush(stdout);
	return run(names[m], m);
}
