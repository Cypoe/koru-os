// threadtest.c — the clone-threads oracle: a static musl ELF driving
// the 0x7d0f00 shape end-to-end. CLONE_VM is proven by a member write
// the leader reads; CLONE_FILES by member stdio; join parks on the
// member's clear_tid futex; getpid agrees across members while gettid
// splits; exit_group kills the tgid. THR COMPLETE fails=N is the row.
#define _GNU_SOURCE
#include <pthread.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <stdio.h>

static int fails;
static volatile int shared;        // leader reads what the member wrote
static volatile int detached_ran;
static volatile long thr_pid, thr_tid;
static volatile int order[8];      // two members, one shared cursor
static volatile int cursor;
static volatile int ran1, ran2;    // deterministic both-ran facts —
                                   // cursor can tear legally
static long main_pid, main_tid;

static void *worker(void *arg) {
    (void)arg;
    printf("THR member ran\n");            // CLONE_FILES: member stdio
    thr_tid = (long)syscall(SYS_gettid);   // the member's own id
    thr_pid = (long)getpid();              // the GROUP's id
    shared = 42;                           // CLONE_VM: shared address space
    return (void *)7;                      // join must return this
}

static void *bump(void *arg) {
    long i = (long)arg;
    if (i == 1) ran1 = 1; else ran2 = 1;
    for (int n = 0; n < 3; n++) {
        int slot = cursor;                 // races are legal; the count
        order[slot & 7] = (int)i;          // of distinct members is the
        cursor = slot + 1;                 // shared-cursor evidence
        usleep(1000);
    }
    return 0;
}

static void *det(void *arg) {
    (void)arg;
    detached_ran = 1;
    return 0;
}

int main(void) {
    main_pid = getpid();
    main_tid = (long)syscall(SYS_gettid);
    printf("THR pid %ld tid %ld\n", main_pid, main_tid);
    if (main_pid != main_tid) {
        printf("THR FAIL main tid %ld != pid %ld\n", main_tid, main_pid);
        fails++;
    }

    pthread_t t;
    void *rv = 0;
    if (pthread_create(&t, 0, worker, 0) != 0) {
        printf("THR FAIL pthread_create\n");
        fails++;
    } else {
        if (pthread_join(t, &rv) != 0) {   // parks on the member's
            printf("THR FAIL join\n");     // clear_tid futex until exit
            fails++;
        }
        if ((long)rv != 7) {
            printf("THR FAIL join retval %ld\n", (long)rv);
            fails++;
        }
        if (shared != 42) {
            printf("THR FAIL shared VA %d\n", shared);
            fails++;
        }
        if (thr_tid == 0 || thr_tid == main_tid) {
            printf("THR FAIL member tid %ld\n", thr_tid);
            fails++;
        }
        if (thr_pid != main_pid) {
            printf("THR FAIL member pid %ld != %ld\n", thr_pid, main_pid);
            fails++;
        }
    }

    // two members on one shared cursor — CLONE_VM again, contended
    pthread_t a, b;
    if (pthread_create(&a, 0, bump, (void *)1) != 0 ||
        pthread_create(&b, 0, bump, (void *)2) != 0) {
        printf("THR FAIL pair create\n");
        fails++;
    } else {
        pthread_join(a, 0);
        pthread_join(b, 0);
        if (!ran1 || !ran2) {
            printf("THR FAIL member ran1=%d ran2=%d\n", ran1, ran2);
            fails++;
        }
        if (cursor < 2) {                  // the shared cursor moved
            printf("THR FAIL shared cursor %d\n", cursor);
            fails++;
        }
    }

    pthread_t d;
    if (pthread_create(&d, 0, det, 0) != 0 || pthread_detach(d) != 0) {
        printf("THR FAIL detach\n");
        fails++;
    } else {
        for (int i = 0; i < 200 && !detached_ran; i++) usleep(10000);
        if (!detached_ran) {
            printf("THR FAIL detached run\n");
            fails++;
        }
    }

    printf("THR COMPLETE fails=%d\n", fails);
    return fails ? 1 : 0;   // exit_group — the tgid reports once
}
