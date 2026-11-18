# Vendored cage — provenance

Upstream: https://github.com/cage-kiosk/cage tag `v0.1.5`
Tarball: `v0.1.5.tar.gz` sha256
`576b8b5a041712b8d8785243ac6db08c7bc9c32822f96ad6dec7ac2b2db9b2b5`

Cage 0.1.5 is the kiosk compositor release paired with wlroots 0.16 —
the version vendored under `koruos/hosted/wlroots`. It is carried
UNMODIFIED (MIT, see LICENSE): `build-cage.sh` compiles the six
non-XWayland translation units against the vendored wlroots/wayland/
xkbcommon/pixman stack, exactly the dep set `build-wlrcomp.sh`
curates.

- `config.h` — handwritten for this tree (meson's `config.h.in`
  output, frozen): `CAGE_HAS_XWAYLAND 0`, `CAGE_VERSION "0.1.5"`.
  XWayland is OFF — the arm has no X11 provider; a request for it
  must refuse, not silently degrade.
- `xwayland.c`/`xwayland.h` — vendored for completeness, never
  compiled (the `#if CAGE_HAS_XWAYLAND` call sites in cage.c fold
  away).
- Omitted upstream files: `meson.build`, `meson_options.txt`,
  `config.h.in`, `cage.1.scd`, `contrib/` — build-system and docs,
  not compile inputs. The file list in `scripts/build-cage.sh`
  mirrors meson's `cage_sources` minus `xwayland.c`.
