// wlrinit.elf — same orchestration as wlinit, but the client is
// wlreal.elf: the REAL vendored libwayland-1.26 binary, not our
// hand-rolled wlwire one. Server stays wlserver.elf — the honest
// asymmetric step: unmodified client library against our compositor.
// NO channel wiring: both children rendezvous on wayland-1 through
// the shared fs view; waits both zombies.
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
    long cp = syscall(KORU_SPAWN_START, "wlreal.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (cp < 0) { printf("WLRINIT FAIL cli spawn %ld\n", cp); return 1; }
    int ss = 0, cs = 0;
    syscall(KORU_WAIT, sp, &ss);
    syscall(KORU_WAIT, cp, &cs);
    printf("WLRINIT srv=%d cli=%d\n", ss, cs);
    printf("WLRINIT COMPLETE\n");
    return (ss == 0 && cs == 0) ? 0 : 1;
}
