// jobctl.c — sessions + job-control child oracle. The process itself
// setsid()s, claims the pty as its ctty (TIOCSCTTY), then drives real
// job-control semantics: a forked job moved into its own pgrp takes
// the foreground (TIOCSPGRP), ^Z through the master stops it,
// waitpid WUNTRACED reports the stop, kill(-pg, SIGCONT) resumes it,
// ^C kills it by signal, and a background reader stops on SIGTTIN.
// Dispositions are the kernel's bookkeeping — the same file compiled
// for linux (else-branch) is the differential twin.
//
// The job handshake runs on a PIPE, not the pty: a child that reads
// the tty in the background takes SIGTTIN and stops before the driver
// can foreground it (a stop is sticky — tcsetpgrp alone never resumes
// one). The pipe can't signal, so the child provably cannot touch the
// terminal until the driver has already foregrounded it — the same
// ordering a real shell relies on.
//
//   KORU_DOOR:  pty pair via syscall(521, sv)
//   else:       posix_openpt/unlockpt — the linux twin
#ifndef KORU_DOOR
#define _XOPEN_SOURCE 600 // posix_openpt/grantpt/unlockpt/ptsname
#endif
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <termios.h>
#include <signal.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

static int m, s;
static int p2c[2], c2p[2]; // go-pipe and ready-pipe per job
static int fails;

static void check(const char *tag, long got, long want) {
    fails += (got != want);
    printf("JC %s got=%ld want=%ld %s\n", tag, got, want,
           got == want ? "ok" : "FAIL");
    fflush(stdout); // a mid-suite death must not take the log with it
}

// A job child: leaves the driver's pgrp, reports ready over the pipe,
// waits for "go" (the driver sends it only after foregrounding —
// never for the TTIN job), then either reads one byte off the tty
// (mode 'r': write 'R', exit 7) or just pause()s as a pure signal
// target (mode 'p' — job2's ^C probe: WSL1's pty read can return a
// spurious EOF across an fg-pgrp swap, which would race the signal).
// Its whole life is observable: the 'S' byte proves setpgid ran
// before the driver foregrounded it.
static void job(char mode) {
    setpgid(0, 0);
    if (write(c2p[1], "S", 1) != 1) _exit(90);
    char b = 0;
    if (read(p2c[0], &b, 1) != 1) _exit(91);
    if (mode == 'p') { pause(); _exit(95); }
    if (read(s, &b, 1) < 0) _exit(92);
    if (write(s, "R", 1) != 1) _exit(93);
    _exit(7);
}

// spawn a job on fresh pipes; returns the pid.
static pid_t spawn_job(char mode) {
    if (pipe(p2c) < 0 || pipe(c2p) < 0) { fails++; return -1; }
    pid_t j = fork();
    if (j == 0) { job(mode); _exit(94); }
    char b;
    if (j > 0 && read(c2p[0], &b, 1) != 1) { fails++; return -1; }
    return j;
}

static void go(void) { if (write(p2c[1], "g", 1) != 1) fails++; }

// read off the master until a wanted byte arrives — ldisc echo
// ('x', '^Z' glyphs) is noise here; the child's own 'R' is the fact.
static int mget(char want) {
    char b;
    for (int i = 0; i < 64; i++) {
        if (read(m, &b, 1) != 1) return -1;
        if (b == want) return 0;
    }
    return -1;
}

int main(void) {
    // The kernel's exec'd child is pid 1 — its own pgrp leader — and
    // like linux's init it cannot setsid. The suite runs in a fork:
    // the grandchild inherits pgrp 1 != its pid, so session creation
    // is lawful — the same shape the linux twin has under bash.
    pid_t me = fork();
    if (me > 0) {
        int st;
        while (waitpid(me, &st, 0) < 0 && errno == EINTR) {}
        return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
    }
    if (me < 0) return 1;
    // the driver becomes a session leader — every job below runs in
    // ITS session, which is what TIOCSPGRP's same-session edge wants.
    // SIGHUP is session noise here (ctty churn), not a job fact — and
    // the SIG_IGN exercises the stored-disposition path on koru.
    // SIGTTOU ignored is what every real shell does: a background
    // caller of TIOCSPGRP takes SIGTTOU on linux, and the driver
    // foregrounds jobs while IT is backgrounded — the ignore is how
    // a shell reclaims the terminal between jobs.
    signal(SIGHUP, SIG_IGN);
    signal(SIGTTOU, SIG_IGN);
    check("setsid", setsid() < 0 ? -1 : 0, 0);
    check("setsid-leader-perm", setsid() < 0 ? errno : 0, EPERM);
    check("getsid-self", getsid(0), getpid());
    check("getpgid-self", getpgid(0), getpid());

    int sv[2] = { -1, -1 };
#ifdef KORU_DOOR
    long r = syscall(521, sv);
    check("openpty", r, 0);
#else
    int mfd = posix_openpt(O_RDWR | O_NOCTTY);
    if (mfd >= 0 && unlockpt(mfd) == 0) {
        sv[0] = mfd;
        char *nm = ptsname(mfd);
        sv[1] = nm ? open(nm, O_RDWR | O_NOCTTY) : -1;
    }
    check("openpty", sv[0] >= 0 && sv[1] >= 0 ? 0 : -1, 0);
#endif
    if (sv[0] < 0 || sv[1] < 0) return 1;
    m = sv[0];
    s = sv[1];

    // claim the ctty — only a session leader may, and ours qualifies.
    check("tiocsctty", ioctl(s, TIOCSCTTY, 0) < 0 ? errno : 0, 0);
    check("tcgetpgrp-self", tcgetpgrp(s), getpgrp());
    check("getsid-ctty", getsid(0), getpid());

    // ---- job 1: the full stop/continue/resume/reap arc -------------
    pid_t j1 = spawn_job('r');
    check("job1-ready", j1 > 0 ? 0 : -1, 0);   // 'S' => setpgid already ran
    check("tcsetpgrp-job1", tcsetpgrp(s, j1) < 0 ? errno : 0, 0);
    check("tcgetpgrp-job1", tcgetpgrp(s), j1);
    check("job1-getpgid", getpgid(j1), j1);    // leads its own pgrp
    go();                                       // it is fg — the tty read is legal

    // ^Z through the master: SIGTSTP to the fg pgrp — the job stops.
    check("vsusp-write", write(m, "\x1a", 1), 1);
    int st = 0;
    pid_t w = waitpid(j1, &st, WUNTRACED);
    check("wait-stopped", w, j1);
    check("wifstopped", WIFSTOPPED(st) ? 1 : 0, 1);
    check("stopsig", WIFSTOPPED(st) ? WSTOPSIG(st) : 0, SIGTSTP);

    // bg: SIGCONT to the pgrp — the job resumes its parked read.
    check("bg-cont", kill(-(int)j1, SIGCONT), 0);
    check("job1-feed", write(m, "x\n", 2), 2); // completes its read
    check("job1-resumed", mget('R'), 0);        // R came after CONT
    st = 0;
    w = waitpid(j1, &st, 0);
    check("wait-exited", w, j1);
    check("exit-status", WIFEXITED(st) ? WEXITSTATUS(st) : -1, 7);
    // a real shell reclaims the foreground between jobs — and the
    // pty must not hang up when a job's fg pgrp dies (WSL1 quirks
    // here; the reclaim is honest regardless).
    check("fg-back1", tcsetpgrp(s, getpgrp()) < 0 ? errno : 0, 0);

    // ---- job 2: ^C kills the foreground job by signal --------------
    pid_t j2 = spawn_job('p');
    check("job2-ready", j2 > 0 ? 0 : -1, 0);
    check("tcsetpgrp-job2", tcsetpgrp(s, j2) < 0 ? errno : 0, 0);
    go();
    check("vintr-write", write(m, "\x03", 1), 1); // ^C
    st = 0;
    w = waitpid(j2, &st, 0);
    check("wait-killed", w, j2);
    check("wifsignaled", WIFSIGNALED(st) ? 1 : 0, 1);
    check("termsig", WIFSIGNALED(st) ? WTERMSIG(st) : 0, SIGINT);

    // ---- job 3: a background reader stops on SIGTTIN ---------------
    check("fg-back2", tcsetpgrp(s, getpgrp()) < 0 ? errno : 0, 0);
    pid_t j3 = spawn_job('r');
    check("job3-ready", j3 > 0 ? 0 : -1, 0);
    go(); // released WITHOUT being foregrounded — its tty read stops it
    st = 0;
    w = waitpid(j3, &st, WUNTRACED);
    check("wait-ttin", w, j3);
    check("ttin-sig", WIFSTOPPED(st) ? WSTOPSIG(st) : 0, SIGTTIN);
    check("bg-kill", kill(-(int)j3, SIGKILL), 0);
    st = 0;
    w = waitpid(j3, &st, 0);
    check("wait-kill", w, j3);
    check("kill-sig", WIFSIGNALED(st) ? WTERMSIG(st) : 0, SIGKILL);

    // the reaped job's pgrp is gone — signalling it is ESRCH.
    check("dead-pgrp-esrch", kill(-(int)j3, 0) < 0 ? errno : 0, ESRCH);

    printf("JC COMPLETE fails=%d\n", fails);
    return fails ? 1 : 0;
}
