// NATIVE, roster rung: an mb2 cpio module carries /bin/roster; the
// initramfs view mounts it and exec spawns it under a TIGHT bag —
// read/write/close/writev + fork/pause/getpid + exit/wait/proc-self
// (bits 0,1,3,20,34,39,57,60,61,62 — nr522 procview folds to 62).
// The child's own RV lines are the evidence: a minted roster fd
// whose snapshot names every live slot — self st=R, the paused peer,
// the zombie, T after SIGTSTP, gone after reap — plus per-slot
// ppid/pgid/sid/stop/bag/nfd as data, and shared-cursor dup semantics.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/initramfs
import std/io

std/io:print.ln("roster: begin")
|> koruos/initramfs:open(module: "roster.cpio")
| ok o |> koruos/initramfs:exec(o.fs, path: "/bin/roster", rights: 8214566287260516363)
    | ok x |> std/io:print.ln("roster: exec /bin/roster ino={{ x.ino:d }} status={{ x.status:d }}")
        |> std/io:print.ln("ROSTER GATE COMPLETE")
    | refused xe |> std/io:print.ln("FAIL exec: {{ xe:s }}")
| refused oe |> std/io:print.ln("FAIL open: {{ oe:s }}")
