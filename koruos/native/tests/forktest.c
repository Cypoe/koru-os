// fork oracle — a real musl binary exercising the POSIX seam end to end:
//   * open()/read() a file through the child's scoped fs view
//   * fork() — musl's _Fork issues a bare nr57 syscall (measured on the
//     toolchain: mov $0x39,%eax; syscall). The kernel copies the address
//     space, dups the fd projection through the provider's refcount, and
//     the child resumes at the post-syscall instruction with rax=0.
//   * the child's read continues at offset 5 — the dup'd fd SHARES the
//     provider's open file (POSIX: one file offset across a fork), while
//     its x=42 lives only in the copied space and never leaks back.
//   * waitpid() → nr61 wait4 with an encoded status word; the child must
//     reap exactly once (zombie) and the code must decode to 33.
//   * clone(CLONE_VM|CLONE_VFORK|SIGCHLD) must refuse by name — only the
//     fork-shaped flag set is served this rung.
#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/wait.h>
#include <sys/syscall.h>

int main(void) {
    int fd = open("/hello.txt", O_RDONLY);
    if (fd < 0) { printf("FORK open errno=%d\n", errno); return 2; }
    char pb[8] = {0};
    if (read(fd, pb, 5) != 5) { printf("FORK pread errno=%d\n", errno); return 3; }
    int x = 1;
    long p = syscall(57); // SYS_fork — exactly what musl _Fork emits
    if (p < 0) { printf("FORK fork errno=%d\n", errno); return 4; }
    if (p == 0) {
        x = 42;
        char cb[8] = {0};
        long n = read(fd, cb, 5); // offset shared with the parent's handle
        printf("FORKC cb=[%.5s] n=%ld x=%d pid=%d\n", cb, n, x, getpid());
        _exit(33);
    }
    int st = 0;
    long w = waitpid((pid_t)p, &st, 0);
    // wait4-encoded status: WIFEXITED tests the low byte, WEXITSTATUS the code
    printf("FORKP p=%ld w=%ld ex=%d st=%d x=%d pb=[%.5s]\n",
           p, w, WIFEXITED(st) ? 1 : 0, WEXITSTATUS(st), x, pb);
    // Only the fork shape is served — shared-space clone refuses by name.
    errno = 0;
    long cv = syscall(56, 0x4111L, 0L, 0L, 0L, 0L); // CLONE_VM|VFORK|SIGCHLD
    printf("FORKC clonev ret=%ld errno=%d\n", cv, errno);
    return 7;
}
