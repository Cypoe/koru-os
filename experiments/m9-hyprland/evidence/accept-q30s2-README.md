# Q30 stage 2 counted runs (explicit hyprland.children grants), 2026-10-19 20:54 CEST

M9 (h1)–(h5)+(x) remain PASS 3/3 under TCG on the same M9 kernel (`595f8c05…`).
Stage 2 adds explicit grants for Hyprland→foot and negatives (ungranted path/fd).

| run | M9 | STAGE2 |
|---|---|---|
| accept-q30s2-run-1 | CHECKS PASS | STAGE2 CHECKS PASS |
| accept-q30s2-run-2 | CHECKS PASS | STAGE2 CHECKS PASS |
| accept-q30s2-run-3 | CHECKS PASS | STAGE2 CHECKS PASS |

Regressions after the tree change: `regress-q30s2/BOARD.txt` (M3–M8b/M7b, Slice A, NID, spawn, spawn-elf) all 3/3 under TCG.

Files per run: `check.txt`, `check-stage2.txt`, `serial.log`, `result.txt`, `drive.txt`, `dod3.txt`, `sha256.txt` (no ppm/GPL/WAD).
