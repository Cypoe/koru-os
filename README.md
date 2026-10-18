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

Licence: not yet chosen.
