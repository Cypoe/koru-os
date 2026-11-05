// NATIVE, unix-socket transport rung: wlpair.elf is a real musl child
// that socketpair()s + fork()s, passes a memfd over SCM_RIGHTS, and the
// server side mmaps it MAP_SHARED — the fd-passing shared-memory
// mechanism the wayland wire is built on.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import std/io

koruos/ext2:mount(id: 0)
| ok m |> koruos/ext2:exec(m.fs, path: "wlpair.elf", rights: 18446744073709551615)
        | ok e |> std/io:print.ln("sock: exec wlpair status={{ e.status:d }}")
            |> koruos/ext2:unmount(e.fs)
                | ok |> std/io:print.ln("WLBOOT COMPLETE")
                | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused e |> std/io:print.ln("FAIL exec wlpair: {{ e.reason:s }}") |> koruos/ext2:unmount(e.fs)
            | ok |> _
            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
