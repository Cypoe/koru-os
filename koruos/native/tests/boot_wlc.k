// NATIVE, nested-compositor rung: wlrcinit.elf spawns wlserver.elf
// (our libwayland-server compositor on /wayland-1, presenting through
// the *Surf seam), wlrcomp.elf (wlroots 0.16 nested compositor — a
// wl_shm/xdg client of /wayland-1 running its own libwayland-server
// display on /wayland-2 with a pixman-rendered scene), and
// wlrinner.elf (unmodified libwayland-1.26 client talking xdg_shell
// to wlroots' implementation). Pixels travel three protocol hops:
// client shm -> wlroots scene -> pixman -> wl_shm -> *Surf -> scanout.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import std/io

koruos/ext2:mount(id: 0)
| ok m |> koruos/ext2:exec(m.fs, path: "wlrcinit.elf", rights: 18446744073709551615)
        | ok e |> std/io:print.ln("wlc: exec wlrcinit status={{ e.status:d }}")
            |> koruos/ext2:unmount(e.fs)
                | ok |> std/io:print.ln("WLCEXEC COMPLETE")
                | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused e |> std/io:print.ln("FAIL exec wlrcinit: {{ e.reason:s }}") |> koruos/ext2:unmount(e.fs)
            | ok |> _
            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
