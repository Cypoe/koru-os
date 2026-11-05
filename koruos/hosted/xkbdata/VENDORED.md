# xkbdata — vendored xkeyboard-config data files

Source: `xkeyboard-config-2.44-1-any.pkg.tar.zst` (Arch Linux archive,
upstream xkeyboard-config 2.44 — arch-independent keymap data only).

- `xkb/` — the complete `usr/share/X11/xkb` tree: `rules/` (including the
  generated `evdev` ruleset), `keycodes/`, `types/`, `compat/`,
  `symbols/`, `geometry/`. 295 files, ~4MB.
- The three upstream symlinks (`rules/xorg{,.xml,.lst}`) are flattened
  into real copies — the native fs view has no symlink resolution, and
  duplicated bytes are the honest shape there.

Consumed by: `koru/native/tests/wlrcomp.c` — staged onto the ext2 image
at `/xkb` by `scripts/check-boot.sh` (`debugfs rdump`), then
`XKB_CONFIG_ROOT=/xkb` lets vendored libxkbcommon compile the real
evdev/us keymap the nested compositor forwards to its clients.
