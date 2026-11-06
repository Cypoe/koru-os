// roster.c — procview/roster-view child oracle. The process mints a
// read-only roster fd, then verifies the kernel's own knowledge as
// data: every live child's pid/ppid/pgid/sid/state/stop/bag/nfd —
// including ITSELF mid-read, a stopped child showing T, a zombie
// showing Z, and a reaped child GONE from the next snapshot. The
// same file compiled for linux reads /proc/<pid>/stat instead — the
// differential twin validates the field semantics, not the bytes.
//
// The roster is the synchronization channel: there are no sleeps and
// no handshake pipes — the parent polls the view until the child
// reports S (parked in pause, so its setpgid provably ran), Z (the
// exit landed), or T (the stop fact booked). Every stat query mints
// a FRESH snapshot — "what is true now", not a stale page.
//
//   KORU_DOOR:  roster fd via syscall(522)
//   else:       /proc/<pid>/stat field parse — the linux twin
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/syscall.h>
#include <sys/wait.h>

static int fails;

static void check(const char *tag, long got, long want) {
    fails += (got != want);
    printf("RV %s got=%ld want=%ld %s\n", tag, got, want,
           got == want ? "ok" : "FAIL");
    fflush(stdout); // a mid-suite death must not take the log with it
}

#ifdef KORU_DOOR
// ---- koru side: the nr522 snapshot fd -----------------------------------
static char snap[4096];

// A FRESH snapshot each call — procview's cursor is per open-file-
// description; a drained fd reads EOF forever after.
static int snap_fresh(void) {
    int fd = (int)syscall(522);
    if (fd < 0) return -1;
    ssize_t n = read(fd, snap, sizeof(snap) - 1);
    close(fd);
    if (n < 0) return -1;
    snap[n] = 0;
    return (int)n;
}

// field "k=" on the "pid=N " line, or -1 when absent. The trailing
// space in the anchor keeps pid=1 from matching inside ppid=10.
static long field_of(long pid, const char *k) {
    char anchor[32], pat[16];
    snprintf(anchor, sizeof(anchor), "pid=%ld ", pid);
    snprintf(pat, sizeof(pat), "%s=", k);
    char *line = strstr(snap, anchor);
    if (!line) return -1;
    char *v = strstr(line, pat);
    if (!v || v > strchr(line, '\n')) return -1;
    return strtol(v + strlen(pat), NULL, 0);
}

static int has_pid(long pid) {
    if (snap_fresh() < 0) return 0;
    return field_of(pid, "pid") == pid;
}
static long st_of(long pid) {
    if (snap_fresh() < 0) return -1;
    char anchor[32];
    snprintf(anchor, sizeof(anchor), "pid=%ld ", pid);
    char *line = strstr(snap, anchor);
    if (!line) return -1;
    char *v = strstr(line, "st=");
    return v ? v[3] : -1;
}
static long kfield_of(long pid, const char *k) {
    if (snap_fresh() < 0) return -1;
    return field_of(pid, k);
}
#define field_of(p, k) kfield_of(p, k)
#else
// ---- linux side: /proc/<pid>/stat ---------------------------------------
// stat line: pid (comm) state ppid pgrp session ... — comm may hold
// spaces, so everything is parsed after the LAST ')'.
static char fields[512];

static int stat_read(long pid) {
    char p[64];
    snprintf(p, sizeof(p), "/proc/%ld/stat", pid);
    int fd = open(p, O_RDONLY);
    if (fd < 0) return -1;
    ssize_t n = read(fd, fields, sizeof(fields) - 1);
    close(fd);
    if (n < 0) return -1;
    fields[n] = 0;
    return 0;
}

static long stat_field(long pid, int idx) {
    // idx counts fields AFTER comm: 1=state(char),2=ppid,3=pgrp,4=session
    if (stat_read(pid) < 0) return -1;
    char *c = strrchr(fields, ')');
    if (!c) return -1;
    c += 2;
    for (int i = 1; i < idx; i++) {
        c = strchr(c, ' ');
        if (!c) return -1;
        c++;
    }
    return idx == 1 ? *c : strtol(c, NULL, 10);
}

static int has_pid(long pid) { return stat_read(pid) == 0; }
static long st_of(long pid) { return stat_field(pid, 1); }
static long field_of(long pid, const char *k) {
    if (!strcmp(k, "ppid")) return stat_field(pid, 2);
    if (!strcmp(k, "pgid")) return stat_field(pid, 3);
    if (!strcmp(k, "sid")) return stat_field(pid, 4);
    return -1;
}
#endif

// The roster-as-barrier: poll until pid reports the wanted state.
// Bounded — a kernel that never converges answers with the timeout's
// fail, not a hang.
static int wait_st(long pid, long want) {
    for (int i = 0; i < 65536; i++)
        if (st_of(pid) == want) return 1;
    return 0;
}
static int wait_not_st(long pid, long not) {
    for (int i = 0; i < 65536; i++) {
        long s = st_of(pid);
        if (s != -1 && s != not) return 1;
    }
    return 0;
}

int main(void) {
    printf("roster: begin\n");
    fflush(stdout);
    pid_t me = getpid();
#ifdef KORU_DOOR
    check("open", snap_fresh() > 0, 1);
#else
    check("open", has_pid(me), 1);
#endif

    // two children: c1 setpgid+pause (a live peer), c2 exits at once
    // (a zombie until reaped).
    pid_t c1 = fork();
    if (c1 == 0) { setpgid(0, 0); pause(); _exit(90); }
    pid_t c2 = fork();
    if (c2 == 0) { _exit(7); }
    if (c1 < 0 || c2 < 0) { fails++; printf("RV fork failed\n"); }

    check("self", has_pid(me), 1);
    check("self-r", st_of(me) == 'R', 1);
    // S means c1 is parked in pause — setpgid provably ran first.
    check("c1-sleeps", wait_st(c1, 'S'), 1);
    check("c2-zomb", wait_st(c2, 'Z'), 1);
    check("kids", has_pid(c1) && has_pid(c2), 1);
    check("ppid", field_of(c1, "ppid") == me, 1);
    check("pgid", field_of(c1, "pgid") == c1, 1);
    check("sid", field_of(c1, "sid") == field_of(me, "sid"), 1);

    kill(c1, SIGTSTP);
    check("stop", wait_st(c1, 'T'), 1);
#ifdef KORU_DOOR
    check("stop-signo", field_of(c1, "stop") == SIGTSTP, 1);
#endif

    kill(c1, SIGCONT);
    check("cont", wait_not_st(c1, 'T'), 1);

    int st;
    waitpid(c2, &st, 0); // reap the zombie — it leaves the next snapshot
    check("gone", has_pid(c2), 0);

#ifdef KORU_DOOR
    check("bag", field_of(me, "bag") != 0, 1);
    check("nfd", field_of(me, "nfd") >= 3, 1);

    // cursor semantics: a drained fd stays EOF; dup SHARES the cursor —
    // the second descriptor's first bytes are offset 8 of the same
    // snapshot, not the snapshot's start.
    int fd = (int)syscall(522);
    char b[16];
    ssize_t n1 = read(fd, b, 8);
    check("partial", n1 == 8, 1);
    int d2 = dup(fd);
    char cont[8];
    ssize_t n2 = read(d2, cont, 8);
    check("dup-cursor", n2 == 8, 1);
    close(d2);
    close(fd);
    if (snap_fresh() >= 16)
        check("dup-shared", memcmp(cont, snap + 8, 8) == 0, 1);
    else
        check("dup-shared", 0, 1);
    fd = (int)syscall(522);
    while (read(fd, snap, sizeof(snap)) > 0) {}
    check("eof", read(fd, snap, sizeof(snap)), 0);
    check("write-refused", write(fd, "x", 1) == -1, 1);
    close(fd);
#endif

    kill(c1, SIGKILL);
    waitpid(c1, &st, 0);
    printf("RV COMPLETE fails=%d\n", fails);
    fflush(stdout);
    return fails ? 1 : 0;
}
