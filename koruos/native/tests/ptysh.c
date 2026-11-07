// ptysh.c — busybox-sh-pty oracle: UNMODIFIED alpine busybox ash
// exec'd onto the slave end of a koru pty, driven by a scripted
// master. The whole terminal chain is on trial: openpty mint,
// setsid + TIOCSCTTY session ownership, fork-inherited ctty,
// execve through the child's fs view, canonical echo, ISIG ->
// fg-pgrp signals, and ash's own job control — `&`, `jobs`, `fg`,
// `^Z`->Stopped, `bg`, `kill %1`, and `^C` killing a fg job.
//
// The oracle's contract is ash's own output: ash speaks job facts in
// shell grammar ("[1] 1234", "Stopped", prompt returns), the driver
// asserts each in order and prints SHP lines — fails>0 is the gate's
// red. The exec'd child is pid 1's grandchild (pid 1 cannot setsid —
// same fork dance as jobctl.c).
//
//   KORU_DOOR:  pty pair via syscall(521, sv); else posix_openpt.
#ifndef KORU_DOOR
#define _XOPEN_SOURCE 600
#endif
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <termios.h>
#include <signal.h>
#include <poll.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <sys/wait.h>

static int m, s, shellpid;
static int fails;
static char acc_buf[4096];

static void check(const char *tag, long got, long want) {
    fails += (got != want);
    printf("SHP %s got=%ld want=%ld %s\n", tag, got, want,
           got == want ? "ok" : "FAIL");
    fflush(stdout);
}

// answer ash's ESC[6n cursor-position query — busybox readline asks
// after each prompt and READS the reply from stdin; bytes arriving
// while it waits are consumed as the "reply". A real terminal
// answers, so must we — or typed commands are eaten and the gate
// measures a starvation artifact instead of the pty stack.
static void feed_reply(const char *b, int nr) {
    for (int i = 0; i + 3 < nr; i++)
        if (b[i] == 0x1b && b[i+1] == '[' && b[i+2] == '6' &&
            b[i+3] == 'n')
            write(m, "\x1b[1;1R", 6);
}

// escape acc for diagnosis: control bytes readable, no line-breaks.
static void dump_acc(const char *want, const char *acc, int n) {
    printf("SHP dump '%s' got:", want);
    for (int i = 0; i < n; i++) {
        unsigned char ch = acc[i];
        if (ch >= 32 && ch < 127) putchar(ch);
        else printf("\\x%02x", ch);
    }
    putchar('\n');
}

// the last expect() capture, for post-hoc assertions (`jobs` grammar
// is the fact — sometimes the check is what must NOT be there).
static char acc[4096];
static int acc_n;
static const char *last_capture(void) { return acc; }

// read the master until `want` appears or the poll budget dies —
// shell output is asynchronous; the window is the honest bound.
static int expect(const char *want, int ms) {
    int n;
    acc_n = n = 0;
    int left = ms;
    while (left > 0) {
        struct pollfd pfd = { .fd = m, .events = POLLIN };
        int r = poll(&pfd, 1, 200);
        if (r < 0) return -1;
        left -= 200;
        if (r == 0) continue;
        char b[256];
        int nr = read(m, b, sizeof(b));
        if (nr <= 0) return -1;
        feed_reply(b, nr);
        for (int i = 0; i < nr && n < (int)sizeof(acc) - 1; i++)
            acc[n++] = b[i];
        acc[n] = 0;
        acc_n = n;
        if (strstr(acc, want)) return 0;
    }
    acc_n = n;
    dump_acc(want, acc, n);
    return -1;
}

// one master round-trip: write the line, then wait for evidence.
static int cmd(const char *line, const char *want, int ms) {
    if (write(m, line, strlen(line)) != (long)strlen(line)) return -1;
    return expect(want, ms);
}

int main(void) {
    pid_t me = fork();
    if (me > 0) {
        int st;
        while (waitpid(me, &st, 0) < 0 && errno == EINTR) {}
        return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
    }
    if (me < 0) return 1;

    // the driver becomes the session leader, then claims the pty —
    // the shape every login shell expects.
    signal(SIGHUP, SIG_IGN);
    signal(SIGTTOU, SIG_IGN);
    check("setsid", setsid() < 0 ? -1 : 0, 0);

    // bisect probe: dynamic busybox exec'd by a plain fork'd child,
    // no pty involved — its own serial line is the verdict.
    {
        pid_t pb = fork();
        if (pb == 0) {
            char *a[] = { "busybox", "echo", "BBPROBE", NULL };
            char *e[] = { "PATH=/bin", NULL };
            execve("/bin/busybox", a, e);
            _exit(112);
        }
        int st = 0;
        pid_t w = waitpid(pb, &st, 0);
        check("bb-probe", WIFEXITED(st) ? WEXITSTATUS(st)
              : WIFSIGNALED(st) ? -(WTERMSIG(st) + 64) : -1, 0);
    }

    int sv[2] = { -1, -1 };
#ifdef KORU_DOOR
    check("openpty", syscall(521, sv), 0);
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
    check("tiocsctty", ioctl(s, TIOCSCTTY, 0) < 0 ? errno : 0, 0);

    // fork the shell: the child inherits session + ctty, slides its
    // stdio onto the slave, and exec's the real busybox. argv[0] is
    // "ash" — the applet name, so dispatch never depends on a link.
    shellpid = fork();
    if (shellpid == 0) {
        dup2(s, 0);
        dup2(s, 1);
        dup2(s, 2);
        char *argv[] = { "ash", NULL };
        char *envp[] = { "PATH=/bin", "TERM=vt100", NULL };
        execve("/bin/busybox", argv, envp);
        _exit(111);
    }
    check("shell-fork", shellpid > 0 ? 0 : -1, 0);
    close(s); // the driver's copy is done — master end stays

    // --- the scripted session -------------------------------------
    // Boot output: whatever ash prints first (prompt or its own
    // "can't access tty" admission) — surfaced raw for diagnosis.
    {
        struct pollfd d = { .fd = m, .events = POLLIN };
        int n = 0;
        for (int i = 0; i < 20 && poll(&d, 1, 250) > 0; i++) {
            int r = read(m, acc_buf + n, sizeof(acc_buf) - 1 - n);
            if (r <= 0) break;
            feed_reply(acc_buf + n, r);
            n += r;
        }
        if (n > 0) { acc_buf[n] = 0; printf("SHP boot-out %d: %.120s\n", n, acc_buf); }
        else printf("SHP boot-out n=0\n");
        fflush(stdout);
    }

    // First line: canonical echo + ash itself. "can't access tty" is
    // ash's own job-control-off admission — it must NOT appear.
    check("jobctl-on", cmd("echo alive\n", "alive", 15000) < 0 ? -1 : 0, 0);

    // `sleep 30 &` — busybox ash prints NO "[1] pid" at launch (measured:
    // only `bg` prints "[1]+ ..."); the job-start fact rides `jobs`.
    check("bg-job", cmd("sleep 30 &\n", "/ $", 8000) < 0 ? -1 : 0, 0);
    check("jobs-running", cmd("jobs\n", "Running", 8000) < 0 ? -1 : 0, 0);

    // fg brings it up; ash echoes the command line it foregrounded.
    check("fg", cmd("fg\n", "sleep 30", 8000) < 0 ? -1 : 0, 0);

    // ^Z through the master: VINTR's stop half — SIGTSTP to the fg
    // pgrp. ash reports "Stopped" when the wait4 says so.
    check("susp", write(m, "\x1a", 1), 1);
    check("stopped", expect("Stopped", 8000) < 0 ? -1 : 0, 0);

    // bg resumes it as a background job — ash echoes "[1]+ sleep 30".
    check("bg-resume", cmd("bg\n", "[1]", 8000) < 0 ? -1 : 0, 0);

    // kill %1 — the builtin returns the prompt silently. This arm's
    // ruling is stored-metadata: a caught handler (ash's SIGCHLD sweep)
    // fires never, so the job table learns the death only through an
    // explicit wait4 — `wait` is the arm's honest consumer. It blocks
    // until the TERM'd job is reaped; if the signal never landed the
    // window dies honestly. $? = 128+15 names the signal itself.
    check("kill-job", cmd("kill %1\n", "/ $", 8000) < 0 ? -1 : 0, 0);
    check("kill-job-wait", cmd("wait %1\n", "/ $", 8000) < 0 ? -1 : 0, 0);
    check("kill-job-status", cmd("echo st=$?\n", "st=143", 8000) < 0 ? -1 : 0, 0);
    {   // the reaped table speaks last: Running would mean the sweep lied.
        int r = cmd("jobs\n", "/ $", 8000);
        if (r == 0)
            check("kill-job-dead",
                  strstr(last_capture(), "Running") ? -1 : 0, 0);
        else check("kill-job-dead", -1, 0);
    }

    // ^C against a foreground job: SIGINT through the ldisc — the job
    // dies and control returns to a live shell (evidence: a fresh
    // command still round-trips). The drain gives ash its scheduling
    // quantum to foreground the sleep before the interrupt.
    check("fg2-wr", write(m, "sleep 30\n", 9), 9);
    { struct pollfd d = { .fd = m, .events = POLLIN }; poll(&d, 1, 400); }
    check("intr", write(m, "\x03", 1), 1);
    check("shell-alive", cmd("echo still\n", "still", 8000) < 0 ? -1 : 0, 0);

    // exit — the shell's status rides waitpid home; 0 means a clean
    // interactive session end-to-end.
    write(m, "exit\n", 5);
    int st = 0;
    pid_t w = waitpid(shellpid, &st, 0);
    check("shell-reaped", w, shellpid);
    // exit status, or -(sig+64) when signaled — the death names its cause.
    check("shell-status", WIFEXITED(st) ? WEXITSTATUS(st)
          : WIFSIGNALED(st) ? -(WTERMSIG(st) + 64) : -1, 0);

    // linux's answer order: buffered bytes first, EIO only after the
    // ring drains AND every slave ref is gone. Drain till -1, then
    // the errno is the verdict.
    {
        char eb;
        while (read(m, &eb, 1) > 0) {}
        check("master-eio", errno, EIO);
    }

    printf("SHP COMPLETE fails=%d\n", fails);
    return fails ? 1 : 0;
}
