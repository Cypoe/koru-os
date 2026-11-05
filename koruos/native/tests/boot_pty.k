// NATIVE, pty rung: an mb2 cpio module carries /bin/ptytest; the
// initramfs view mounts it and exec spawns it under a TIGHT bag —
// read/write/close/writev + the channel class (bit 22 — openpty,
// ioctl, poll, signalfd all fold there) + exit. The child's own PTY
// lines are the evidence: canonical echo/erase/kill, ISIG->pending
// SIGINT, TIOCSWINSZ->SIGWINCH, ICRNL, OPOST/ONLCR, raw mode, EIO.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/initramfs
import std/io

std/io:print.ln("pty: begin")
|> koruos/initramfs:open(module: "pty.cpio")
| ok o |> koruos/initramfs:exec(o.fs, path: "/bin/ptytest", rights: 5764607523039477771)
    | ok x |> std/io:print.ln("pty: exec /bin/ptytest ino={{ x.ino:d }} status={{ x.status:d }}")
        |> std/io:print.ln("PTY GATE COMPLETE")
    | refused xe |> std/io:print.ln("FAIL exec: {{ xe:s }}")
| refused oe |> std/io:print.ln("FAIL open: {{ oe:s }}")
