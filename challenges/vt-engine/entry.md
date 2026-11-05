---
name: vt-engine
iface: koruos/term.vt
arms: [koru-native, hosted]
lane: donor-c
needs: [pty-termios]
accept: vttest + esctest pass-rate against a real terminal on the slave end
tier: qemu
status: open
evidence: —
peer: —
provenance: foot terminal.c (MIT) is the readable donor; contour alternative
---

# vt-engine

The terminal emulator: VT parser + grid + scrollback + attributes,
rendered onto *Surf — the userspace side a pty slave actually feeds.
"Terminal" splits into kernel job (pty+ldisc, landed) and this — the
thing that turns the byte stream into a screen.

## Acceptance

vttest + esctest suites driven at the emulator's pty slave — pass rate
measured and reported (no emulator passes 100%; the number is the
claim). A real shell prompt inside a compositor window is the
milestone-9-style end-to-end.

## Notes

- foot's terminal.c (~2.5k lines, MIT, wayland-native) is the readable
  donor; contour is the C++ alternative; writing koru-native is the
  long-run answer.
- Glyph/font path (PSF2 or real font stack) is a sub-problem — decide
  early whether vt-engine renders to *Surf pixels or a text cell grid
  the compositor draws.
