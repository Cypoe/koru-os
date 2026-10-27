// wlinit.elf — orchestrates a wl session the way a session does:
// socketpair(2), then two spawn_starts projecting each end into a
// SEPARATE binary's fd0 (the socket is stdin, conout stays stdout).
// Closes its own ends — the children hold the endpoint refs — and
// waits both zombies. EOS on last-close is the server's exit cue.
#include <stdio.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#define KORU_SPAWN_START 513
#define KORU_WAIT 61
#define NO_FD (~0UL)

int main(void) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        printf("WLINIT FAIL socketpair\n");
        return 1;
    }
    // absent blob → argv[0] defaults to the path (POSIX's convention)
    long sp = syscall(KORU_SPAWN_START, "wlserver.elf", ~0UL, 0, 0,
                      (long)sv[0], NO_FD);
    if (sp < 0) { printf("WLINIT FAIL srv spawn %ld\n", sp); return 1; }
    long cp = syscall(KORU_SPAWN_START, "wlclient.elf", ~0UL, 0, 0,
                      (long)sv[1], NO_FD);
    if (cp < 0) { printf("WLINIT FAIL cli spawn %ld\n", cp); return 1; }
    close(sv[0]);
    close(sv[1]);
    int ss = 0, cs = 0;
    syscall(KORU_WAIT, sp, &ss);
    syscall(KORU_WAIT, cp, &cs);
    printf("WLINIT srv=%d cli=%d\n", ss >> 8, cs >> 8);
    printf("WLINIT COMPLETE\n");
    return 0;
}
