# Vendored wayland client — provenance

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
- `src/` — libwayland-client 1.26.0 sources (MIT), from
  gitlab.freedesktop.org/wayland/wayland tag 1.26.0:
  `wayland-client.c`, `connection.c`, `wayland-os.c`,
  `wayland-util.c` + private headers. `config.h` here is handwritten
  for linux/musl (only `HAVE_ACCEPT4`).
- `libffi/` — `libffi.a` (musl x86_64), `ffi.h`, `ffitarget.h` from
  Alpine `libffi-dev-3.4.6-r0` (MIT). Wayland demarshals listener
  closures through ffi — its only external dep.

To regenerate the protocol glue: `hosted/vroot/` — `wayland-scanner
private-code wayland.xml wayland-client-protocol.c` etc., inside the
jail (`wayland-scanner` is in the Arch package).
