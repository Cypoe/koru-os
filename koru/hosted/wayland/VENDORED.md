# Vendored wayland client + server — provenance

The `linux-wayland` hosted arm carries its wire stack in-repo so the
binary is musl-static with zero runtime deps (the host's
libwayland-client.so.0 is 1.18 — predates `wl_proxy_marshal_flags`;
Arch's 1.26 needs glibc 2.38). Compiled in:

- `wayland-client.h`, `wayland-client-core.h`, `wayland-util.h`,
  `wayland-version.h` — public client headers, generated/copied inside
  the vendored Arch vroot (wayland 1.26.0-1).
- `wayland-client-protocol.c/.h` — `wayland-scanner` private-code +
  client-header output for `wayland.xml`, generated in the vroot.
- `xdg-shell-client-protocol.h`, `xdg-shell-protocol.c` — same, for
  `stable/xdg-shell/xdg-shell.xml`.
- `src/` — libwayland 1.26.0 sources (MIT), from
  gitlab.freedesktop.org/wayland/wayland tag 1.26.0 — BOTH halves:
  - client: `wayland-client.c`, `connection.c`, `wayland-os.c`,
    `wayland-util.c` + private headers (`wayland-private.h`,
    `timespec-util.h`).
  - server: `wayland-server.c`, `event-loop.c`, `wayland-shm.c` +
    `wayland-server.h`, `wayland-server-core.h`,
    `wayland-server-private.h`. `connection.c`/`wayland-os.c`/
    `wayland-util.c` are shared — the server build reuses them, it
    does not duplicate.
  - `config.h` here is handwritten for linux/musl (only
    `HAVE_ACCEPT4`).
- `wayland-server-protocol.h`, `wayland-protocol.c` —
  `wayland-scanner` server-header + private-code output for
  `wayland.xml` (the server side's interface tables + typed impl
  vtables + `wl_*_send_*` inlines).
- `xdg-shell-server-protocol.h` — server-header output for
  `stable/xdg-shell/xdg-shell.xml`; `xdg-shell-protocol.c` (above) is
  the shared interface blob both sides link.
- `libffi/` — `libffi.a` (musl x86_64), `ffi.h`, `ffitarget.h` from
  Alpine `libffi-dev-3.4.6-r0` (MIT). Wayland demarshals listener
  closures through ffi — its only external dep.

The server build's kernel appetite beyond the client's: `epoll_*`
(its event loop — nr 213/233/232/281/291), `eventfd2` (the display's
`terminate_efd`, nr 284/290), `getsockopt(SO_PEERCRED)` (per
`wl_client_create`, nr 55). `timerfd`/`signalfd` exist only behind
`wl_event_loop_add_timer`/`add_signal`, which the seam's fixtures do
not call.

To regenerate the protocol glue: `hosted/vroot/` — `wayland-scanner
private-code wayland.xml wayland-protocol.c`, `wayland-scanner
server-header wayland.xml wayland-server-protocol.h`,
`wayland-scanner server-header xdg-shell.xml xdg-shell-server-protocol.h`
etc., inside the jail (`wayland-scanner` is in the Arch package).
