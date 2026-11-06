// exec.c — execve rung child. Stage 1 (this file's main) opens a
// MARKER fd, then execl()s ITSELF with the stage-2 argv — the same
// image swapped in place. Stage 2 (argv[1]=="stage2") verifies the
// POSIX exec contract on the koru arm: the pid survived, the pgid/sid
// survived, the pre-swap fd still reads (the marker byte lands), the
// bag survived (a refused syscall still refuses), and argv is FRESH —
// the stage-2 strings the exec vector carried, not stage-1's.
//
//   KORU_DOOR / linux:  identical — execve is musl's nr59 either way;
//                       the twin measures the contract, not the door.
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <sys/syscall.h>

#ifdef KORU_DOOR
#define MARKER "/marker.txt" // the initramfs view's own root
#define SELF "/bin/exec"
#else
#define MARKER "./marker.txt" // the twin runs from a scratch dir
#define SELF "./exec"
#endif

static int fails;

static void check(const char *tag, long got, long want) {
    fails += (got != want);
    printf("EX %s got=%ld want=%ld %s\n", tag, got, want,
           got == want ? "ok" : "FAIL");
    fflush(stdout); // a mid-suite death must not take the log with it
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "stage2")) {
        // ---- stage 2: post-swap — stage1's identity arrives as data
        // in argv; POSIX says the swap keeps it.
        check("argv-swap", argc == 6 && !strcmp(argv[2], "fresh"), 1);
        check("pid-survives", getpid() == atoi(argv[3]), 1);
        check("pgrp-survives", getpgid(0) == atoi(argv[4]), 1);
        check("sid-survives", getsid(0) == atoi(argv[5]), 1);
        // the marker fd: stage1 dup'd it to fd 7 — a surviving
        // projection still reads its byte.
        char b = 0;
        ssize_t n = read(7, &b, 1);
        check("fd-survives", n == 1 && b == 'K', 1);
#ifdef KORU_DOOR
        // a refused capability still refuses — the bag rode the swap.
        errno = 0;
        long r = syscall(521, (long[2]){0, 0}); // openpty — not in bag
        check("bag-survives", r == -1 && errno == EACCES, 1);
#endif
        printf("EX COMPLETE fails=%d\n", fails);
        fflush(stdout);
        return fails ? 1 : 0;
    }

    // ---- stage 1: pre-swap — own identity goes in argv so stage 2
    // can check survival as a self-contained assertion.
    printf("exec: begin\n");
    fflush(stdout);
    char pid_s[16], pgrp_s[16], sid_s[16];
    snprintf(pid_s, sizeof(pid_s), "%ld", (long)getpid());
    snprintf(pgrp_s, sizeof(pgrp_s), "%ld", (long)getpgid(0));
    snprintf(sid_s, sizeof(sid_s), "%ld", (long)getsid(0));
    // the marker: a byte written through the fs view, dup'd to a fixed
    // high fd (7) — the projection must survive the image swap.
    int fd = open(MARKER, O_RDONLY);
    if (fd < 0) { printf("EX open failed\n"); fflush(stdout); return 90; }
    if (dup2(fd, 7) != 7) { printf("EX dup2 failed\n"); fflush(stdout); return 91; }
    close(fd);
    // swap into the same image, stage-2 argv. execl resolves /bin/exec
    // through the same view the loader used.
    execl(SELF, "exec", "stage2", "fresh", pid_s, pgrp_s, sid_s, (char *)0);
    printf("EX exec failed errno=%d\n", errno); // exec returns only on error
    fflush(stdout);
    return 92;
}
