// NATIVE, real-compositor rung: mount ext2 on our own virtio-blk,
// exec cageinit.elf — which spawn_starts wlserver.elf (libwayland-
// server compositor, /wayland-1, *Surf seam onto virtio-gpu) and
// fork+execves UNMODIFIED upstream cage 0.1.5. Cage's wlroots 0.16
// wayland backend nests on /wayland-1 as an xdg toplevel (appid
// "wlroots"), wl_display_add_socket_auto mints /wayland-0 for hosted
// clients, and cage's own spawn_primary_client fork+execvps Debian's
// unmodified /usr/bin/foot — which maps its toplevel inside cage and
// posix_openpts a pty for shellproof. Four real protocol hops: foot
// → cage → wlserver → *Surf.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import std/io

koruos/ext2:mount(id: 0)
| ok m |> koruos/ext2:exec(m.fs, path: "cageinit.elf", rights: 18446744073709551615)
        | ok e |> std/io:print.ln("cage: exec cageinit status={{ e.status:d }}")
            |> koruos/ext2:unmount(e.fs)
                | ok |> std/io:print.ln("CAGE COMPLETE")
                | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused e |> std/io:print.ln("FAIL exec cageinit: {{ e.reason:s }}")
            |> koruos/ext2:unmount(e.fs)
                | ok |> _
                | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
