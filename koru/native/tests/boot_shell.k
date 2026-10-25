// NATIVE, shell rung: sh.elf is a musl ring-3 REPL — prompt "koru> ",
// per-char blocking read(0) (IRQ1 wakes), then nr 57 spawn: the typed
// name loads through sh's own fs view, joins the roster, and sh's saved
// rax takes the child's exit status when it dies. sendkey drives the
// console; "uname<ret>" is the discriminating command (5-lib closure),
// "q<ret>" exits 47.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import std/io

koruos/ext2:mount(id: 0)
| ok m |> koruos/ext2:exec(m.fs, path: "sh.elf", rights: 8214566270097626927)
        | ok e |> std/io:print.ln("shell: exec sh status={{ e.status:d }}")
            |> koruos/ext2:unmount(e.fs)
                | ok |> std/io:print.ln("SHELL COMPLETE")
                | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused e |> std/io:print.ln("FAIL exec sh: {{ e.reason:s }}") |> koruos/ext2:unmount(e.fs)
            | ok |> _
            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
