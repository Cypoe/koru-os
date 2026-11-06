// NATIVE, exec rung: an mb2 cpio module carries /bin/exec + a marker
// file; the initramfs view mounts it and exec spawns it under a TIGHT
// bag — fs-object open + read/write/close/writev + pause/getpid +
// create-class (57 — nr59 execve folds onto the rebirth family) +
// exit/wait/proc-self. Stage 1 execl()s ITSELF: the swap must keep
// pid/session/bag/fd projection while argv/env land fresh — the EX
// lines are the evidence, and a refused capability must still refuse
// after the swap (the bag rode it, not the image).
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/initramfs
import std/io

std/io:print.ln("exec: begin")
|> koruos/initramfs:open(module: "exec.cpio")
| ok o |> koruos/initramfs:exec(o.fs, path: "/bin/exec", rights: 8214566287260516367)
    | ok x |> std/io:print.ln("exec: exec /bin/exec ino={{ x.ino:d }} status={{ x.status:d }}")
        |> std/io:print.ln("EXEC GATE COMPLETE")
    | refused xe |> std/io:print.ln("FAIL exec: {{ xe:s }}")
| refused oe |> std/io:print.ln("FAIL open: {{ oe:s }}")
