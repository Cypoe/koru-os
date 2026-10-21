// NATIVE, two ELF children on one roster: mount the ext2 image, fetch
// childA.elf + childB.elf, run them in one epoch via koruos/spawn:run2 —
// the PIT tick rotates the two user contexts (each parks its GP frame in
// its own slot on switch), and both exit codes come home through the
// seam. Serial interleave of their single-char writes is the concurrency
// evidence; sched: switches=N the instrument count.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import koruos/spawn
import std/io

koruos/ext2:mount(id: 0)
| ok m |> std/io:print.ln("multi: mounted")
    |> koruos/ext2:fetch(m.fs, name: "childA.elf")
        | ok a |> koruos/ext2:fetch(a.fs, name: "childB.elf")
            | ok b |> koruos/spawn:run2(image_ptr: a.buf.ptr, image_len: a.buf.len, image2_ptr: b.buf.ptr, image2_len: b.buf.len, rights: 1152921504606846978)
                | ok e |> std/io:print.ln("multi: roster drained last={{ e:d }}")
                    |> koruos/ext2:unmount(b.fs)
                        | ok |> std/io:print.ln("MULTI COMPLETE")
                        | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                | refused e |> std/io:print.ln("FAIL run2: {{ e:s }}") |> koruos/ext2:unmount(b.fs)
                    | ok |> _
                    | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
            | refused b |> std/io:print.ln("FAIL fetchB: {{ b.reason:s }}") |> koruos/ext2:unmount(b.fs)
                | ok |> _
                | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused a |> std/io:print.ln("FAIL fetchA: {{ a.reason:s }}") |> koruos/ext2:unmount(a.fs)
            | ok |> _
            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
