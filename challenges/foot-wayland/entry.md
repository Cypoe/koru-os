---
name: foot-wayland
iface: koruos/oracle.foot
arms: [koru-native]
lane: oracle
needs: [ptmx-devpts, sessions-jobctl]
accept: unmodified Debian foot maps an xdg toplevel AND its pty child runs a shell
tier: qemu
status: landed
evidence: V
peer: —
provenance: Debian forky foot 1.28 binary, fetched by scripts/fetch-foot.sh
---

# foot-wayland

The desktop-client oracle: Debian's **unmodified** `/usr/bin/foot`
(glibc 2.43 + fontconfig + freetype + harfbuzz + fcft + xkbcommon
closure, resolved by the real `ld-linux-x86-64.so.2`) connects to our
wlserver, negotiates xdg-shell, and presents a real terminal window —
while its own pty child execs a shell through devpts. One binary
exercises the whole desktop claim at once: dynamic linking, fonts,
wayland protocol, shm, pty, sessions, ext2.

## Acceptance

Met. `foot-real` in `scripts/check-boot.sh` asserts serial evidence:
`FOOTINIT wayland-1 bound` (connect + globals), `WLSRV appid foot` +
`toplevel configure` (xdg role), `comp: paint 693x494 nb=…` (real
pixels through shm → scene → virtio-gpu), and `FOOTINIT SHELLPROOF`
(the pty child's ext2 marker — proof the fork/exec/devpts chain ran a
real program). foot stays alive holding the window; the gate polls
the marker rather than waiting on exit.

## Notes

- Served globals the client demanded: `wl_subcompositor` (sync subs,
  deferred commits), `wl_data_device_manager` (selection offers relay
  real fds via SCM_RIGHTS), `wl_output` (geometry/mode/scale/done from
  the live scene extent), `wl_region` (real add/subtract impl).
- foot's `shell=` config/`SHELL` env is only honored when locale init
  succeeds — a bad locale silently swaps the spawn for `/bin/sh -c ""`.
  The image stages `en_US.utf8` locale data for that gate.
- Everything glibc-specific that broke was a syscall/fs/compositor
  gap, never a libc shim gap — glibc-shim's waiver now has measured
  backing: fstat-mode truth, d_type derivation, lazy 512 MiB shm,
  memfd seals, devpts doors, termios2, cwd tracking, prctl/pdeathsig.
- Next rung up the same ladder: wlroots-based clients, then Hyprland.
