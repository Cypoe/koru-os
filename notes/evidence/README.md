# Evidence

Evidence for the plex-os and plex-shell studies (`notes/plex-os-study.md`,
`notes/plex-shell-crates.md`). Produced on the shared box on 2026-10-18 (Europe/Berlin)
under QEMU with TCG.

| file | what it is |
|---|---|
| `boot_plexos.py` | harness: boots the plex-os kernel in `qemu-system-i386` and captures serial output |
| `plexos-serial.log` | serial log of that boot: cyberboot frames, then the `plex-os>` REPL |
| `boot_doom.py`, `boot_doom_play.py` | harnesses that boot plex-os with DOOM as multiboot modules and take QEMU screendumps |
| `doom-serial.log`, `doom-play.log` | serial logs of those runs (text only) |
| `plex-shell-cargo-test.log` | `cargo test` output for the plex-shell workspace |

**Not committed, on purpose:** the DOOM WAD, the DOOM binaries, and the screendumps of
the DOOM runs, because they render id Software's shareware WAD artwork. No game data is
in this repository. The scripts take paths to them as arguments.
