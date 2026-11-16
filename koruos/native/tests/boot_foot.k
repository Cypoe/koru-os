// NATIVE, real-terminal-client rung: mount ext2 on our own virtio-blk,
// exec footinit.elf — which spawn_starts wlserver.elf (libwayland-server
// compositor, /wayland-1, *Surf seam onto virtio-gpu) and fork+execves
// Debian's UNMODIFIED /usr/bin/foot against it: PT_INTERP pulls
// /lib64/ld-linux through the fs view, ld.so resolves the glibc+fcft+
// freetype+fontconfig+harfbuzz closure, foot connects wayland-1, maps
// an xdg toplevel through wl_shm buffers, posix_openpts a pty and
// execs busybox ash onto it. The serial line carries the refusal list
// for whatever the seam can't yet serve — that list IS the work order.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import std/io

koruos/ext2:mount(id: 0)
| ok m |> koruos/ext2:exec(m.fs, path: "footinit.elf", rights: 18446744073709551615)
        | ok e |> std/io:print.ln("foot: exec footinit status={{ e.status:d }}")
            |> koruos/ext2:unmount(e.fs)
                | ok |> std/io:print.ln("FOOT COMPLETE")
                | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused e |> std/io:print.ln("FAIL exec footinit: {{ e.reason:s }}")
            |> koruos/ext2:unmount(e.fs)
                | ok |> _
                | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
