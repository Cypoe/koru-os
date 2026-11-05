// NATIVE, real libwayland rung: wlrinit.elf spawns wlserver.elf (our
// compositor endpoint) and wlreal.elf — the vendored libwayland-1.26
// client built UNMODIFIED (connection/wayland-client/wayland-os/
// wayland-util + generated protocol glue + libffi demarshalling).
// They rendezvous on the filesystem socket "wayland-1": mknod + bind
// + listen + accept on one side, socket + connect + ppoll + recvmsg
// MSG_DONTWAIT + SCM_RIGHTS + fcntl F_DUPFD on the other — the same
// syscalls a linux client makes. Globals, shm formats, surface/pool/
// buffer, pool fd over ancillary, commit -> callback.done + release,
// sync roundtrip — wire-identical to the hand-rolled pair, now proven
// against the real library.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import std/io

koruos/ext2:mount(id: 0)
| ok m |> koruos/ext2:exec(m.fs, path: "wlrinit.elf", rights: 18446744073709551615)
        | ok e |> std/io:print.ln("wlr: exec wlrinit status={{ e.status:d }}")
            |> koruos/ext2:unmount(e.fs)
                | ok |> std/io:print.ln("WLREXEC COMPLETE")
                | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused e |> std/io:print.ln("FAIL exec wlrinit: {{ e.reason:s }}") |> koruos/ext2:unmount(e.fs)
            | ok |> _
            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
