// NATIVE, wl protocol pair rung: wlinit.elf spawns two SEPARATE
// binaries — wlserver.elf (compositor endpoint) and wlclient.elf —
// that rendezvous through the filesystem socket "wayland-1": mknod +
// bind + listen on one side, socket + connect on the other. They speak
// real libwayland wire format: registry globals, shm formats, surface +
// shm_pool + buffer objects, the pool fd crossing SCM_RIGHTS, attach/
// damage/frame/commit answered by callback.done + buffer.release, and
// a display sync — the honest intermediate toward libwayland
// unmodified on this transport (proven by boot_wlr's wlreal.elf).
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import std/io

koruos/ext2:mount(id: 0)
| ok m |> koruos/ext2:exec(m.fs, path: "wlinit.elf", rights: 18446744073709551615)
        | ok e |> std/io:print.ln("wl: exec wlinit status={{ e.status:d }}")
            |> koruos/ext2:unmount(e.fs)
                | ok |> std/io:print.ln("WLEXEC COMPLETE")
                | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused e |> std/io:print.ln("FAIL exec wlinit: {{ e.reason:s }}") |> koruos/ext2:unmount(e.fs)
            | ok |> _
            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
