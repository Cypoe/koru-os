# koru-os

koru-os is a platform namespace for [Koru](https://github.com/korulang/koru), beside
`std`. It has optional platform arms: Unikraft, hosted, plex-os i686, and later others.
Every system interface is an identity bound by a correspondence row, and anything
unbound is refused loudly.

**Status: DRAFT.** This repository holds design documents and early, measured
experiments. Nothing here is a working operating system yet.

- Design: [`docs/design/DESIGN-0001-execution-contract.md`](docs/design/DESIGN-0001-execution-contract.md)
  (DRAFT 5).
- Definition of Done: §0 of DESIGN-0001. In short:
  1. a real filesystem;
  2. a real shell and real programs (cyberboot as the test);
  3. Hyprland with a terminal;
  4. declarative UI with QML as the exemplar.

  All four must pass in QEMU on a koru-os arm with drivers in driver silos. Hosted Linux
  is an oracle, never a pass.
- Studies: [`notes/plex-os-study.md`](notes/plex-os-study.md),
  [`notes/plex-shell-crates.md`](notes/plex-shell-crates.md), with evidence in
  [`notes/evidence/`](notes/evidence/).

Evidence classes used throughout: **V** verified at a pinned SHA, **M** measured on the
box (log given), **C** carried-over claim, **D** design only.

## Upstream provenance (`origins.lock`)

[`origins.lock`](origins.lock) is a [vand](https://github.com/Lolaplex/vand) provenance ledger
(format version 1). It pins every upstream git source that koru-os builds or reads to an exact
commit. `target` paths are relative to a clone root (on the build box this is `/workspace`):

| name | origin | revision | target | role |
|------|--------|----------|--------|------|
| koru | korulang/koru | `3d81f837` | `tc/koru` | Koru compiler used for all `koruos/*` builds |
| koru-libs | korulang/koru-libs | `ff5cb559` | `tc/koru-libs` | Koru libraries (read only here; Q33) |
| unikraft | unikraft/unikraft | `7351f8b5` | `upstream/unikraft` | Unikraft core (kraft channel `stable`) |
| lib-libelf | unikraft/lib-libelf | `c03d4ceb` | `upstream/lib-libelf` | libelf (kraft `stable`) |
| app-elfloader-stable | unikraft/app-elfloader | `6ecbcd08` | `upstream/app-elfloader` | elfloader inside kraft build trees (`stable`) |
| app-elfloader | unikraft/app-elfloader | `0cd7a2b2` | `m3/app-elfloader` | `staging` reference clone (M3) |
| unikraft-catalog | unikraft/catalog | `476b59ce` | `m3/catalog` | catalog reference (M3) |
| libudev-zero | illiliti/libudev-zero | `8f1d3d06` | `m7bin/src/libudev-zero` | ISC libudev; local change in `patches/libudev-zero-udev_monitor.patch` |
| foot | dnkl/foot (Codeberg) | `ab33c9a1` | `m9src/foot` | source reference for the M9 terminal |
| aquamarine | hyprwm/aquamarine | `f31c47a1` | `m9src/aquamarine` | source reference for Hyprland's backend |
| kolibrios | KolibriOS/kolibrios | `45b134ba` | `upstream/kolibrios` | second donor tree (fasm kernel, int 0x40 ABI, GUI, drivers) — oracle/reference, unstudied |

How the Unikraft pins were derived: the build trees are fetched by kraft as branch tarballs
(`archive/refs/heads/stable.tar.gz`). The commit is the tarball's pax `comment` header, and it
matched `git ls-remote … refs/heads/stable` on 2026-10-19. Every file that differs between that
tarball and the `m9k4`, `msmmu` and `spelf` build trees is covered by a patch in `patches/` or
`experiments/*/patches/` (checked mechanically).

Not covered by the lock (vand v1 pins git sources only): the Debian forky packages for M9
(Hyprland 0.56.2, foot 1.28.0, Mesa 26.1.6 and closure), listed by name and version in
`experiments/m9-hyprland/inputs-debs.txt`, and the busybox 1.37.0 release tarball
(busybox.net). Neither binaries nor packages are committed.

Use:

```sh
python3 -m venv ~/.local/share/vand-venv && ~/.local/share/vand-venv/bin/pip install -e <vand-clone>
vand replicate origins.lock --root <clone-root> --dry-run   # inspect first
```

Caution: on a real `replicate`, vand's fallback heuristic runs `make install` for libudev-zero
(it has no `source.yml`), which installs into `/usr/local`. Use `--dry-run` or replicate that
entry by hand.

Licence: not yet chosen.
