// wlrcinit.elf — the nested-compositor rung's orchestrator. Three
// real binaries rendezvous on the shared fs view:
//
//   wlserver.elf  — libwayland-server compositor, /wayland-1,
//                   presents through the *Surf seam to virtio-gpu
//   wlrcomp.elf   — wlroots 0.16 nested compositor: a wl_shm/xdg
//                   client of /wayland-1, serving /wayland-2 with a
//                   pixman-rendered scene graph
//   wlrinner.elf  — wlreal.elf built -DWLREAL_SOCK=/wayland-2, an
//                   unmodified libwayland-1.26 client talking xdg_shell
//                   to wlroots' own implementation
//
// Pixels travel client-shm -> wlrcomp scene -> pixman -> wl_shm
// -> wlserver *Surf -> virtio-gpu scanout: three protocol hops.
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

#define KORU_SPAWN_START 513
#define KORU_WAIT 61
#define NO_FD (~0UL)

int main(void) {
    long sp = syscall(KORU_SPAWN_START, "wlserver.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (sp < 0) { printf("WLRCINIT FAIL srv spawn %ld\n", sp); return 1; }
    long cp = syscall(KORU_SPAWN_START, "wlrcomp.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (cp < 0) { printf("WLRCINIT FAIL comp spawn %ld\n", cp); return 1; }
    long c1 = syscall(KORU_SPAWN_START, "wlrinner.elf", ~0UL, 0, 0,
                      NO_FD, NO_FD);
    if (c1 < 0) { printf("WLRCINIT FAIL inner spawn %ld\n", c1); return 1; }
    int ss = 0, sc = 0, s1 = 0;
    syscall(KORU_WAIT, c1, &s1);   // the innermost client finishes first
    syscall(KORU_WAIT, sp, &ss);   // wlserver exits when all sessions EOS
    syscall(KORU_WAIT, cp, &sc);   // wlrcomp exits last
    printf("WLRCINIT srv=%d comp=%d inner=%d\n", ss, sc, s1);
    printf("WLRCINIT COMPLETE\n");
    return (ss == 0 && sc == 0 && s1 == 0) ? 0 : 1;
}
