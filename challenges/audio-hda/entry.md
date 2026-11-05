---
name: audio-hda
iface: koruos/audio.pcm
arms: [koru-native]
lane: native-zig
needs: [pci-enumeration]
accept: intel-hda codec init + a PCM buffer played (wav on serial evidence)
tier: qemu
status: open
evidence: —
peer: koru-desktop/providers/audio-hda
provenance: —
---

# audio-hda

Intel HDA: CORB/RIRB codec verbs, stream DMA, PCM playback. QEMU's
`-device intel-hda -device hda-duplex` is the qemu tier.

## Acceptance

Codec probe (vendor/dev id via CORB/RIRB), stream setup, a short PCM
buffer played through — serial evidence of ring progress; hw tier is
the audible check.

## Notes

- Lowest-priority driver slot — nothing user-facing needs it yet.
