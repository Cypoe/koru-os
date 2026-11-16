// NATIVE, clone-threads rung: an mb2 cpio module carries /bin/threadtest
// — a static musl oracle driving clone(0x7d0f00), the full musl pthread
// flag set. Members share the group's ProcShared: one upd, one descriptor
// table, one disposition set; join parks on the member's clear_tid futex;
// exit_group kills the tgid and the leader's slot is the one reap. The
// bag is the shpty grant set — the channel class (22) already folds
// clone/futex/tid syscalls. THR COMPLETE fails=0 is the evidence.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/initramfs
import std/io

std/io:print.ln("thr: begin")
|> koruos/initramfs:open(module: "thread.cpio")
| ok o |> koruos/initramfs:exec(o.fs, path: "/bin/threadtest", rights: 8214566321624457007)
    | ok x |> std/io:print.ln("thr: exec /bin/threadtest ino={{ x.ino:d }} status={{ x.status:d }}")
        |> std/io:print.ln("THREAD GATE COMPLETE")
    | refused xe |> std/io:print.ln("FAIL exec: {{ xe:s }}")
| refused oe |> std/io:print.ln("FAIL open: {{ oe:s }}")
