// ptytest.c — pty+termios+ldisc child oracle. Mints a master/slave
// pair through the koru door (nr521 — the ptmx file view is a later
// cell), then drives every contract the terminal stack needs:
// canonical editing (echo/erase/kill/VEOL), ISIG -> pending facts,
// TIOCSWINSZ -> SIGWINCH, ICRNL input map, OPOST/ONLCR output map,
// raw mode, and linux's EIO shape on the dead end. Every check prints
// its own evidence; exit 0 only if all of it landed.
//
//   KORU_DOOR:  pty pair via syscall(521, sv)
//   else:       posix_openpt/unlockpt — the linux differential twin
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <termios.h>
#include <poll.h>
#include <signal.h>
#include <sys/syscall.h>
#include <sys/ioctl.h>
#include <sys/signalfd.h>

static int m, s;
static int fails;

static void hexline(const char *tag, const char *buf, long n) {
    printf("PTY %s hex=", tag);
    for (long i = 0; i < n; i++) printf("%02x", (unsigned char)buf[i]);
    printf("\n");
}

static void check(const char *tag, long got, long want) {
    fails += (got != want);
    printf("PTY %s got=%ld want=%ld %s\n", tag, got, want,
           got == want ? "ok" : "FAIL");
}

static void drain(int fd) {
    char b[512];
    int n = 1;
    while (n > 0) {
        n = 0;
        ioctl(fd, FIONREAD, &n);
        if (n > 0) read(fd, b, sizeof(b));
    }
}

int main(void) {
    int sv[2] = { -1, -1 };
#ifdef KORU_DOOR
    long r = syscall(521, sv);
    check("openpty", r, 0);
#else
    errno = 0;
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
#ifndef KORU_DOOR
    /* linux only: ISIG/SIGWINCH deliver to the foreground pgrp of the
       pty's session — none exists until we make it our ctty. koru's
       model queues the fact on the pair's owner instead; no setsid
       syscall exists there to fake. */
    setsid();
    if (ioctl(s, TIOCSCTTY, 0) < 0) printf("PTY ctty errno=%d\n", errno);
    signal(SIGHUP, SIG_IGN); // session noise, not a pty-mechanics fact
#endif

    struct termios t;
    check("tcgets", ioctl(s, TCGETS, &t), 0);
    printf("PTY lflag=%08lx iflag=%08lx oflag=%08lx\n",
           (unsigned long)t.c_lflag, (unsigned long)t.c_iflag,
           (unsigned long)t.c_oflag);
    check("lflag-sane", t.c_lflag & (ISIG | ICANON | ECHO | ECHOE | ECHOK),
          ISIG | ICANON | ECHO | ECHOE | ECHOK);

    char buf[128];

    /* canonical edit: "hee\x7fllo\n" -> cooked line "hello\n",
       echo on the master side shows "hee" + BS SP BS + "llo\r\n". */
    check("canon-wr", write(m, "hee\x7f" "llo\n", 8), 8);
    check("canon-rd", read(s, buf, sizeof(buf)), 6);
    buf[6] = 0;
    check("canon-cmp", strcmp(buf, "hello\n"), 0);
    check("canon-echo", read(m, buf, sizeof(buf)), 11);
    hexline("canon-echo", buf, 11);

    /* VKILL (0x15) drops the unflushed line — "ab^Ucd\n" -> "cd\n". */
    check("kill-wr", write(m, "ab\x15" "cd\n", 6), 6);
    check("kill-rd", read(s, buf, sizeof(buf)), 3);
    buf[3] = 0;
    check("kill-cmp", strcmp(buf, "cd\n"), 0);
    long ke = read(m, buf, sizeof(buf)); // evidence, not assertion —
    hexline("kill-echo", buf, ke);       //   shapes may lawfully differ
    drain(m);

    /* VINTR: pending SIGINT fact + input queue flushed + ^C echo. */
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGINT);
    sigaddset(&mask, SIGWINCH);
    /* signalfd only claims BLOCKED signals — unblocked, the ^C's real
       SIGINT terminates us before the fd ever sees it (measured: the
       linux twin died 128+2). koru queues facts regardless, but the
       block is the honest contract on both sides. */
    sigprocmask(SIG_BLOCK, &mask, NULL);
    int sfd = signalfd(-1, &mask, 0);
    check("signalfd", sfd >= 0 ? 0 : -1, 0);
    check("sig-wr", write(m, "zz\x03", 3), 3);
    struct signalfd_siginfo si;
    check("sig-read", read(sfd, &si, sizeof(si)) == sizeof(si) ? 0 : -1, 0);
    check("sig-signo", si.ssi_signo, SIGINT);
    /* linux flushes the UNCOMMITTED echo ring on a signal — typed "zz"
       never reaches the master ("^C" alone, 2 bytes). koru echoes
       eagerly into the out-ring, so "zz^C" (4) is the lawful shape
       there. Assert the glyph lands at the END either way. */
    long se = read(m, buf, sizeof(buf));
    check("sig-echo", se >= 2 && buf[se - 2] == '^' && buf[se - 1] == 'C'
          ? 0 : -1, 0);
    hexline("sig-echo", buf, se);

    /* the flushed queue really is empty: fresh input cooks cleanly. */
    check("post-sig-wr", write(m, "ok\n", 3), 3);
    check("post-sig-rd", read(s, buf, sizeof(buf)), 3);
    buf[3] = 0;
    check("post-sig-cmp", strcmp(buf, "ok\n"), 0);
    drain(m);

    /* winsz round-trip + SIGWINCH on set. */
    struct winsize { unsigned short row, col, xp, yp; } ws;
    check("getws", ioctl(s, TIOCGWINSZ, &ws), 0);
    check("ws-zero", ws.row | ws.col, 0);
    ws.row = 24;
    ws.col = 80;
    check("setws", ioctl(s, TIOCSWINSZ, &ws), 0);
    memset(&si, 0, sizeof(si));
    check("winch-read", read(sfd, &si, sizeof(si)) == sizeof(si) ? 0 : -1, 0);
    check("winch-signo", si.ssi_signo, SIGWINCH);
    ws.row = ws.col = 0;
    check("getws2", ioctl(s, TIOCGWINSZ, &ws), 0);
    check("ws-now", (ws.row << 16) | ws.col, (24 << 16) | 80);
    unsigned ptn = 0;
    int pr = ioctl(m, TIOCGPTN, &ptn);
    if (pr < 0) printf("PTY getptn errno=%d\n", errno);
    check("getptn", pr, 0);
    printf("PTY ptn=%u\n", ptn);

    /* raw mode: ICANON+ECHO off — bytes pass through uncooked. */
    check("tcgets2", ioctl(s, TCGETS, &t), 0);
    t.c_lflag &= ~(ICANON | ECHO);
    check("tcsets-raw", ioctl(s, TCSETS, &t), 0);
    check("raw-wr", write(m, "q7", 2), 2);
    check("raw-rd", read(s, buf, sizeof(buf)), 2);
    check("raw-cmp", memcmp(buf, "q7", 2), 0);

    /* ICRNL with canonical back on: \r cooks to a line-ending \n. */
    check("tcgets3", ioctl(s, TCGETS, &t), 0);
    t.c_lflag |= ICANON;
    check("tcsets-canon", ioctl(s, TCSETS, &t), 0);
    check("icrnl-wr", write(m, "a\rb\n", 4), 4);
    check("icrnl-rd1", read(s, buf, sizeof(buf)), 2);
    check("icrnl-cmp1", memcmp(buf, "a\n", 2), 0);
    check("icrnl-rd2", read(s, buf, sizeof(buf)), 2);
    check("icrnl-cmp2", memcmp(buf, "b\n", 2), 0);
    drain(m); // icrnl echo (ECHO off — nothing should be there, drain anyway)

    /* OPOST|ONLCR output transform: slave \n -> master \r\n. */
    check("onlcr-wr", write(s, "x\ny\n", 4), 4);
    check("onlcr-rd", read(m, buf, sizeof(buf)), 6);
    hexline("onlcr", buf, 6);
    /* OPOST off: no transform at all. */
    check("tcgets4", ioctl(s, TCGETS, &t), 0);
    t.c_oflag &= ~OPOST;
    check("tcsets-noopost", ioctl(s, TCSETS, &t), 0);
    check("rawout-wr", write(s, "p\nq\n", 4), 4);
    check("rawout-rd", read(m, buf, sizeof(buf)), 4);
    hexline("rawout", buf, 4);

    /* dead-end shape: slave close -> master EIO on read AND write. */
    check("close-s", close(s), 0);
    errno = 0;
    check("m-eio-read", read(m, buf, sizeof(buf)) < 0 ? errno : 0, EIO);
    errno = 0;
    check("m-eio-write", write(m, "z", 1) < 0 ? errno : 0, EIO);
    struct pollfd pfd = { .fd = m, .events = POLLIN };
    check("m-poll", poll(&pfd, 1, 0) > 0 &&
          (pfd.revents & POLLERR ? 1 : 0), 1);
    check("close-m", close(m), 0);

    printf("PTY COMPLETE fails=%d\n", fails);
    return fails ? 1 : 0;
}
