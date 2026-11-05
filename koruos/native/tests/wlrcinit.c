// wlrcinit.elf — the nested-compositor rung's orchestrator. Three
// real binaries rendezvous on the shared fs view:
//
//   wlserver.elf  — libwayland-server compositor, /wayland-1,
//                   presents through the *Surf seam to virtio-gpu
//   wlrcomp.elf   — wlroots 0.16 nested compositor: a wl_shm/xdg
//                   client of /wayland-1, serving /wayland-2 with a
//                   pixman-rendered scene graph
//   wlrinner.elf  — wlreal.elf built -DWLREAL_SOCK=/wayland-2, an
//                   unmodified libwayland-1.26 client talking xdg_shell
//                   to wlroots' own implementation
//
// Pixels travel client-shm -> wlrcomp scene -> pixman -> wl_shm
// -> wlserver *Surf -> virtio-gpu scanout: three protocol hops.
//
// The launcher's own loop is the signalfd/timerfd proof: the deaths it
// waits() for also land as signalfd_siginfo bytes on a queue the kernel
// produces from spawned_by, and a periodic timerfd armed before the
// chain accrues real expirations while the compositors run.
#include <stdio.h>
#include <signal.h>
#include <sys/signalfd.h>
#include <sys/timerfd.h>
#include <sys/syscall.h>
#include <unistd.h>

#define KORU_SPAWN_START 513
#define KORU_WAIT 61
#define NO_FD (~0UL)

static void drain_sfd(int sfd, const char *tag) {
    struct signalfd_siginfo si;
    int n = 0;
    while (read(sfd, &si, sizeof si) == sizeof si) {
        printf("WLRC sigchld pid=%u st=%d\n",
               si.ssi_pid, si.ssi_status);
        n++;
    }
    printf("WLRC sfd %s drained=%d\n", tag, n);
}

int main(void) {
    sigset_t sm;
    sigemptyset(&sm);
    sigaddset(&sm, SIGCHLD);
    sigprocmask(SIG_BLOCK, &sm, NULL);
    int sfd = signalfd(-1, &sm, SFD_NONBLOCK);
    printf("WLRC sfd=%d\n", sfd);

    int tfd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK);
    if (tfd >= 0) {
        struct itimerspec its;
        its.it_value.tv_sec = 0;
        its.it_value.tv_nsec = 110 * 1000 * 1000;   // ~2 ticks
        its.it_interval.tv_sec = 0;
        its.it_interval.tv_nsec = 110 * 1000 * 1000;
        timerfd_settime(tfd, 0, &its, NULL);
    }
    printf("WLRC tfd=%d\n", tfd);

    long sp = syscall(KORU_SPAWN_START, "wlserver.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (sp < 0) { printf("WLRCINIT FAIL srv spawn %ld\n", sp); return 1; }
    long cp = syscall(KORU_SPAWN_START, "wlrcomp.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (cp < 0) { printf("WLRCINIT FAIL comp spawn %ld\n", cp); return 1; }
    long c1 = syscall(KORU_SPAWN_START, "wlrinner.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (c1 < 0) { printf("WLRCINIT FAIL inner spawn %ld\n", c1); return 1; }
    int ss = 0, sc = 0, s1 = 0;
    syscall(KORU_WAIT, c1, &s1);   // the innermost client finishes first
    if (sfd >= 0) drain_sfd(sfd, "inner");
    syscall(KORU_WAIT, sp, &ss);   // wlserver exits when all sessions EOS
    if (sfd >= 0) drain_sfd(sfd, "srv");
    syscall(KORU_WAIT, cp, &sc);   // wlrcomp exits last
    if (sfd >= 0) drain_sfd(sfd, "comp");

    if (tfd >= 0) {
        unsigned long long n = 0;
        if (read(tfd, &n, 8) == 8)
            printf("WLRC tfd n=%llu\n", n);
        else
            printf("WLRC tfd read fail\n");
    }
    printf("WLRCINIT srv=%d comp=%d inner=%d\n", ss, sc, s1);
    printf("WLRCINIT COMPLETE\n");
    return (ss == 0 && sc == 0 && s1 == 0) ? 0 : 1;
}
