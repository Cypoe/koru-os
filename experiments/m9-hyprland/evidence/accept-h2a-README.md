# M9 counted re-run (h2a via Q30 stage 1), 2026-10-19 20:19–20:22 CEST

TCG only. Kernel `m7-input_qemu-x86_64` sha256 `595f8c052016e5a8ead7b6c44bc953c9006bd86b902244e305e0035aa5a9f369` (unchanged).

| run | wall_s | check.py |
|-----|--------|----------|
| accept-h2a-run-1 | 56.042 | CHECKS PASS |
| accept-h2a-run-2 | 55.226 | CHECKS PASS |
| accept-h2a-run-3 | 55.642 | CHECKS PASS |

(h2a): Hyprland `hl.dsp.exec_cmd('/usr/bin/foot --pty=/dev/korupty0')` returns `ok` via
`libhypr-spawn-compat.so` (`fork` → `posix_spawnp`). Init-launched foot workaround off
(`M9_FOOT_PTY=0`). See `../spawn-compat/README.md`.
