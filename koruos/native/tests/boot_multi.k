// NATIVE, two ELF children on one roster — fetched BY NESTED PATH:
// mount the ext2 image, walk /bin/childA.elf and /bin/childB.elf (the
// path is a projection — lookup names the inode identity underneath),
// run both in one epoch via koruos/spawn:run2. The PIT tick rotates the
// two user contexts; serial interleave of their single-char writes is
// the concurrency evidence, sched: switches=N the instrument count.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import koruos/spawn
import std/io

koruos/ext2:mount(id: 0)
| ok m |> koruos/ext2:lookup(m.fs, path: "/bin/childA.elf")
    | ok l |> std/io:print.ln("multi: /bin/childA.elf -> ino {{ l.ino:d }}")
        |> koruos/ext2:fetch(l.fs, path: "/bin/childA.elf")
            | ok a |> koruos/ext2:fetch(a.fs, path: "/bin/childB.elf")
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
    | refused l |> std/io:print.ln("FAIL lookup: {{ l.reason:s }}") |> koruos/ext2:unmount(l.fs)
        | ok |> _
        | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
