// wlinit.elf — orchestrates a wl session the way a session does with
// pathname endpoints: NO channel wiring at all. It spawns the server
// and the client into the same fs view; the server binds wayland-1
// there, the client connects through the shared namespace — the fs
// node IS the rendezvous, exactly like XDG_RUNTIME_DIR on unix.
// stdout stays fd1 for both; waits both zombies.
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

#define KORU_SPAWN_START 513
#define KORU_WAIT 61
#define NO_FD (~0UL)

int main(void) {
    // absent blob → argv[0] defaults to the path (POSIX's convention);
    // NO_FD wiring → both children keep default conin/conout.
    long sp = syscall(KORU_SPAWN_START, "wlserver.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (sp < 0) { printf("WLINIT FAIL srv spawn %ld\n", sp); return 1; }
    long cp = syscall(KORU_SPAWN_START, "wlclient.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (cp < 0) { printf("WLINIT FAIL cli spawn %ld\n", cp); return 1; }
    int ss = 0, cs = 0;
    syscall(KORU_WAIT, sp, &ss);
    syscall(KORU_WAIT, cp, &cs);
    printf("WLINIT srv=%d cli=%d\n", ss >> 8, cs >> 8);
    printf("WLINIT COMPLETE\n");
    return 0;
}
