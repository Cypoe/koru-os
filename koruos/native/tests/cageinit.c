// cageinit.elf — the real-compositor rung's orchestrator. Three real
// binaries rendezvous on the shared fs view:
//
//   wlserver.elf — libwayland-server compositor, /wayland-1,
//                  presents through the *Surf seam to virtio-gpu
//   cage.elf     — UNMODIFIED upstream cage 0.1.5 (wlroots 0.16
//                  kiosk): its wayland backend nests on /wayland-1
//                  (xdg toplevel, appid "wlroots"), serves its own
//                  socket /wayland-0 to hosted clients
//   /usr/bin/foot — Debian's unmodified terminal, spawned BY CAGE
//                  through its own fork+execvp primary-client path
//
// The chain is four real protocol hops — foot → cage → wlserver →
// *Surf — and the pixels cross all of them: foot's shm buffers are
// composited by cage's pixman scene into the nested output frame
// wlserver blits to the gpu.
//
// spawn_start carries no envp, so cage launches through a forked
// execve with the env it needs: WAYLAND_DISPLAY selects the wayland
// backend (upstream autocreate), XDG_RUNTIME_DIR roots both socket
// namespaces, and foot's own contract (SHELL/TERM/LANG) rides through
// cage's environ into the grandchild.
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/syscall.h>

#define KORU_SPAWN_START 513
#define NO_FD (~0UL)

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0); // evidence can't die in a buffer
    // the image is persistent — a stale marker from a previous boot
    // would satisfy the poll before cage's foot ever spawns.
    unlink("/footproof");
    long sp = syscall(KORU_SPAWN_START, "wlserver.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (sp < 0) { printf("CAGEINIT FAIL srv spawn %ld\n", sp); return 1; }
    printf("CAGEINIT srv spawned\n");

    // wait for wlserver's S_IFSOCK inode — the wayland backend's
    // wl_display_connect would answer ECONNREFUSED before bind lands.
    struct stat sb;
    int tries = 0;
    while (tries < 200 && stat("/wayland-1", &sb) != 0) {
        struct timespec ts = { 0, 60 * 1000 * 1000 }; // ~a tick
        nanosleep(&ts, NULL);
        tries++;
    }
    if (tries >= 200) {
        printf("CAGEINIT FAIL wayland-1 never bound\n");
        return 1;
    }
    printf("CAGEINIT wayland-1 bound tries=%d\n", tries);

    pid_t cp = fork();
    if (cp == 0) {
        // cage [-dhm:sv] <app> [args...] — -d asks server-side
        // decoration (foot's csd.preferred=none pairs with it);
        // argv+optind becomes the primary client cage itself
        // fork+execvps once the backend is up.
        char *argv[] = { "cage", "-d",
                         "/usr/bin/foot",
                         "-o", "csd.preferred=none",
                         "-o", "scrollback.lines=64",
                         "-o", "shell=/shellproof.elf",
                         NULL };
        char *envp[] = {
            // upstream socket: wlr_backend_autocreate sees this and
            // picks the wayland backend — the nesting is REAL, not
            // a headless shortcut.
            "WAYLAND_DISPLAY=wayland-1",
            "WLR_BACKENDS=wayland",
            "WAYLAND_DEBUG=1",
            // wl_display_connect joins "$XDG_RUNTIME_DIR/$DISPLAY"
            // and cage's add_socket_auto mints the hosted socket in
            // the same dir — "/" lands /wayland-0 at the view root.
            "XDG_RUNTIME_DIR=/",
            // the Debian-staged xkb-data tree — xkb_context_new's
            // default include-path stat must land somewhere real or
            // the context refuses at birth.
            "XKB_CONFIG_ROOT=/usr/share/X11/xkb",
            "HOME=/tmp",
            "XDG_CONFIG_HOME=/etc/xdg",
            "PATH=/usr/bin:/bin",
            // foot's contract rides environ through cage's execvp —
            // cage only overrides WAYLAND_DISPLAY for the child.
            "SHELL=/shellproof.elf",
            "TERM=foot",
            "LANG=en_US.UTF-8",
            NULL,
        };
        execve("/cage.elf", argv, envp);
        _exit(111);
    }
    if (cp < 0) { printf("CAGEINIT FAIL cage fork %d\n", cp); return 1; }
    printf("CAGEINIT cage forked pid=%d\n", cp);

    // cage holds foot as its own child — the observable proof is the
    // same as foot-real's: shellproof.elf lands /footproof on this
    // ext2 view once foot's pty chain produces a live process INSIDE
    // cage's hosted display.
    struct stat psb;
    int ptries = 0;
    while (ptries < 800 && stat("/footproof", &psb) != 0) {
        struct timespec ts = { 0, 50 * 1000 * 1000 };
        nanosleep(&ts, NULL);
        ptries++;
    }
    if (ptries >= 800)
        printf("CAGEINIT FAIL footproof never landed\n");
    else
        printf("CAGEINIT SHELLPROOF sz=%ld\n", (long)psb.st_size);

    printf("CAGEINIT COMPLETE\n");

    // Grace: the shell proof lands BEFORE the composited frame's
    // first damage reaches the outer scene — foot's font threads
    // and its first real frame need ~20s from connect. Let the real
    // pixels blit before teardown.
    { struct timespec gs = { 9, 0 }; nanosleep(&gs, NULL); }

    // Epoch drain: upstream cage 0.1.5's SIGTERM path is self-broken —
    // wl_event_loop_add_signal is handed &server.wl_display (a
    // wl_display**) while handle_signal reads it as wl_display*, so
    // wl_display_terminate reads terminate_efd from +0xd0 of the
    // server struct (a heap pointer), write() answers EBADF — exactly
    // what linux answers — and libwayland's wl_abort fires. Verified
    // against the pristine 0.1.5 tarball: the bug is upstream's, and
    // SIGKILL is the honest teardown for an unmodified binary.
    // kill(-1) because the roster holds grandchildren cageinit cannot
    // name — foot (cage's own primary-client fork+exec), its font
    // threads, and the pty session leader. A socket-HUP exit would
    // also be honest, but the drain's contract is "every descendant
    // exits", so the orchestrator makes that explicit.
    kill(-1, SIGKILL);
    waitpid(cp, NULL, 0);
    waitpid((pid_t)sp, NULL, 0);
    return 0;
}
