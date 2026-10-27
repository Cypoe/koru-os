// wlpair: the unix-socket transport rung's evidence child.
// socketpair + fork = two processes sharing a SOCK_STREAM channel;
// the client memfd_create's a pool, writes magic into the shared
// pages, and passes the fd over SCM_RIGHTS — the wayland wire's real
// mechanism. The server recvmsg's the fd, mmaps it MAP_SHARED, and
// reads the client's pixels back out of the same frames.
#define _GNU_SOURCE
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

int main(void) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        printf("WLPAIR FAIL socketpair=%d\n", sv[0]);
        return 1;
    }
    pid_t p = fork();
    if (p == 0) {
        // client: owns the pool, passes the fd like wl_shm does
        int mfd = syscall(319, "wlpool", 0);
        if (mfd < 0) { printf("WLCLNT FAIL memfd\n"); _exit(2); }
        ftruncate(mfd, 8192);
        unsigned *pool = mmap(0, 8192, PROT_READ | PROT_WRITE,
                              MAP_SHARED, mfd, 0);
        if (pool == MAP_FAILED) { printf("WLCLNT FAIL mmap e=%d\n", errno); _exit(3); }
        pool[0] = 0xdeadbeef;
        pool[4] = 0xc0ffee;
        char go[6] = "wl-go";
        struct iovec iov = { .iov_base = go, .iov_len = 5 };
        char cbuf[64] = {0};
        struct msghdr mh = {0};
        mh.msg_iov = &iov;
        mh.msg_iovlen = 1;
        mh.msg_control = cbuf;
        mh.msg_controllen = sizeof(cbuf);
        struct cmsghdr *cm = CMSG_FIRSTHDR(&mh);
        cm->cmsg_level = SOL_SOCKET;
        cm->cmsg_type = SCM_RIGHTS;
        cm->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(cm), &mfd, sizeof(int));
        mh.msg_controllen = CMSG_SPACE(sizeof(int));
        long n = sendmsg(sv[1], &mh, 0);
        char rep[8] = {0};
        struct iovec riov = { .iov_base = rep, .iov_len = 4 };
        struct msghdr rmh = { .msg_iov = &riov, .msg_iovlen = 1 };
        long rn = recvmsg(sv[1], &rmh, 0);
        printf("WLCLNT sent=%ld reply=%ld:%s\n", n, rn, rep);
        _exit(0);
    }
    // server: receives the greeting + the pool fd
    char buf[16] = {0};
    struct iovec iov = { .iov_base = buf, .iov_len = 8 };
    char cbuf[64] = {0};
    struct msghdr mh = {0};
    mh.msg_iov = &iov;
    mh.msg_iovlen = 1;
    mh.msg_control = cbuf;
    mh.msg_controllen = sizeof(cbuf);
    long n = recvmsg(sv[0], &mh, 0);
    struct cmsghdr *cm = CMSG_FIRSTHDR(&mh);
    int rfd = -1;
    if (cm && cm->cmsg_level == SOL_SOCKET && cm->cmsg_type == SCM_RIGHTS)
        memcpy(&rfd, CMSG_DATA(cm), sizeof(int));
    printf("WLSERV bytes=%ld:%s rfd=%d\n", n, buf, rfd);
    if (rfd < 0) { printf("WLPAIR FAIL no-fd\n"); return 4; }
    unsigned *shm = mmap(0, 8192, PROT_READ | PROT_WRITE,
                         MAP_SHARED, rfd, 0);
    if (shm == MAP_FAILED) { printf("WLSERV FAIL mmap\n"); return 5; }
    printf("WLSERV magic=%08x tag=%08x\n", shm[0], shm[4]);
    // hand a byte back the other way — the pair is really duplex
    char ok[3] = "ok";
    struct iovec siov = { .iov_base = ok, .iov_len = 2 };
    struct msghdr smh = { .msg_iov = &siov, .msg_iovlen = 1 };
    sendmsg(sv[0], &smh, 0);
    wait(0);
    printf("WLPAIR COMPLETE\n");
    return 0;
}
