// wlrinit.elf — same orchestration as wlinit, but the clients are
// wlreal.elf: the REAL vendored libwayland-1.26 binary, not our
// hand-rolled wlwire one. Server stays wlserver.elf — the honest
// asymmetric step: unmodified client library against our compositor.
// TWO clients: each mints its own *Surf through commit, the seat's
// routed input must reach the right session — multi-client is the
// point, not a second binary for its own sake. NO channel wiring:
// all rendezvous on wayland-1 through the shared fs view.
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

#define KORU_SPAWN_START 513
#define KORU_WAIT 61
#define NO_FD (~0UL)

int main(void) {
    long sp = syscall(KORU_SPAWN_START, "wlserver.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (sp < 0) { printf("WLRINIT FAIL srv spawn %ld\n", sp); return 1; }
    long c1 = syscall(KORU_SPAWN_START, "wlreal.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (c1 < 0) { printf("WLRINIT FAIL cli1 spawn %ld\n", c1); return 1; }
    long c2 = syscall(KORU_SPAWN_START, "wlreal.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (c2 < 0) { printf("WLRINIT FAIL cli2 spawn %ld\n", c2); return 1; }
    int ss = 0, s1 = 0, s2 = 0;
    syscall(KORU_WAIT, sp, &ss);
    syscall(KORU_WAIT, c1, &s1);
    syscall(KORU_WAIT, c2, &s2);
    printf("WLRINIT srv=%d cli=%d,%d\n", ss, s1, s2);
    printf("WLRINIT COMPLETE\n");
    return (ss == 0 && s1 == 0 && s2 == 0) ? 0 : 1;
}
