// footinit.elf — the real-terminal-client rung's orchestrator. Two
// real binaries rendezvous on the shared fs view:
//
//   wlserver.elf  — libwayland-server compositor, /wayland-1,
//                   presents through the *Surf seam to virtio-gpu
//   /usr/bin/foot — Debian forky's UNMODIFIED foot 1.28 terminal
//                   emulator (glibc + fcft/freetype/fontconfig/
//                   harfbuzz closure): connects to wlserver, maps an
//                   xdg toplevel, forks a shell onto its own pty
//
// The shell itself is alpine busybox ash — foot spawns $SHELL through
// posix_openpt+fork+exec, so the pty/session/ctty chain is exercised
// end-to-end by a real terminal emulator, not our driver.
//
// spawn_start carries no envp, so foot launches through a forked
// execve — the env is real: WAYLAND_DISPLAY names wlserver's socket,
// HOME/XDG_RUNTIME_DIR/SHELL answer what glibc/fontconfig/foot ask.
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/syscall.h>

#define KORU_SPAWN_START 513
#define KORU_WAIT 61
#define NO_FD (~0UL)

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0); // evidence can't die in a buffer
    long sp = syscall(KORU_SPAWN_START, "wlserver.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (sp < 0) { printf("FOOTINIT FAIL srv spawn %ld\n", sp); return 1; }
    printf("FOOTINIT srv spawned\n");

    // wait for wlserver's S_IFSOCK inode — connect() would answer
    // ECONNREFUSED before bind lands, and foot exits on that.
    struct stat sb;
    int tries = 0;
    while (tries < 200 && stat("/wayland-1", &sb) != 0) {
        struct timespec ts = { 0, 60 * 1000 * 1000 }; // ~a tick
        nanosleep(&ts, NULL);
        tries++;
    }
    if (tries >= 200) {
        printf("FOOTINIT FAIL wayland-1 never bound\n");
        return 1;
    }
    printf("FOOTINIT wayland-1 bound tries=%d\n", tries);

    pid_t fp = fork();
    if (fp == 0) {
        // csd.preferred=none: no server-decoration protocol is offered
        // and CSD needs wl_subcompositor — "none" draws a bare window,
        // the honest answer on this compositor.
        char *argv[] = { "foot", "-o", "csd.preferred=none",
                         "-o", "scrollback.lines=64",
                         // shell= is belt-and-suspenders: SHELL env is
                         // consulted, but foot swaps the spawn for a
                         // dummy /bin/sh -c "" when locale init fails —
                         // LANG below is the real gate.
                         "-o", "shell=/shellproof.elf", NULL };
        char *envp[] = {
            "WAYLAND_DISPLAY=wayland-1",
            "HOME=/tmp",
            // libwayland joins "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" —
            // wlserver bound "wayland-1" at the view root, so "/" is
            // the runtime dir that lands the connect on /wayland-1.
            "XDG_RUNTIME_DIR=/",
            "XDG_CONFIG_HOME=/etc/xdg",
            "PATH=/usr/bin:/bin",
            // SHELL lands on foot's own pty: the proof wrapper writes
            // /footproof on the ext2 view, then execs a real shell —
            // the spawn chain's observable side effect.
            "SHELL=/shellproof.elf",
            "TERM=foot",
            "LANG=en_US.UTF-8",
            NULL,
        };
        execve("/usr/bin/foot", argv, envp);
        _exit(111);
    }
    if (fp < 0) { printf("FOOTINIT FAIL foot fork %d\n", fp); return 1; }
    printf("FOOTINIT foot forked pid=%d\n", fp);

    // foot stays alive as long as its window lives — waitpid can't be
    // the oracle. The shell proof is observable instead: shellproof.elf
    // lands /footproof on this same ext2 view once foot's pty chain
    // (posix_openpt->pts->fork->execve) produces a live process.
    struct stat psb;
    int ptries = 0;
    while (ptries < 600 && stat("/footproof", &psb) != 0) {
        struct timespec ts = { 0, 50 * 1000 * 1000 };
        nanosleep(&ts, NULL);
        ptries++;
    }
    if (ptries >= 600)
        printf("FOOTINIT FAIL footproof never landed\n");
    else
        printf("FOOTINIT SHELLPROOF sz=%ld\n", (long)psb.st_size);

    printf("FOOTINIT COMPLETE\n");

    // Grace: the shell proof lands BEFORE foot's first damage commit
    // reaches the scene — measured a few hundred ms out. Tearing down
    // at once would kill foot mid-frame and the paint evidence would
    // never blit. Let the real frame land first.
    { struct timespec gs = { 3, 0 }; nanosleep(&gs, NULL); }

    // The .k's exec is a whole-epoch spawn: koru_spawn_run returns only
    // when the roster drains, so foot (its window holds it alive) and
    // wlserver (it listens forever) are the orchestrator's teardown.
    // Their exits close the epoch — then unmount runs and FOOT
    // COMPLETE prints.
    kill(fp, SIGKILL);
    waitpid(fp, NULL, 0);
    kill((pid_t)sp, SIGKILL);
    waitpid((pid_t)sp, NULL, 0);
    return 0;
}
