// NATIVE, ext2 over our own virtio-blk: mount a host-made ext2 image on
// koru-native, create /dod1, read it back, unmount — the same DoD-1 flow
// the unikraft arm runs, on a substrate that owns the device itself.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import koruos/spawn
import std/io

koruos/ext2:mount(id: 0)
| ok m |> std/io:print.ln("ext2n: mounted blocks={{ m.blocks:d }} free_blocks={{ m.free_blocks:d }} inodes={{ m.inodes:d }} free_inodes={{ m.free_inodes:d }}")
    |> koruos/ext2:create(m.fs, name: "dod1", size: 10000)
        | ok c |> std/io:print.ln("ext2n: created dod1 ino={{ c.ino:d }} blocks={{ c.blocks:d }} first_block={{ c.first_block:d }}")
            |> koruos/ext2:verify(c.fs, name: "dod1", size: 10000)
                | ok v |> std/io:print.ln("ext2n: read back dod1 ino={{ v.ino:d }} bytes={{ v.bytes:d }} content=ok")
                    |> koruos/ext2:fetch(v.fs, name: "child.elf")
                        | ok r |> std/io:print.ln("ext2n: read child.elf bytes={{ r.buf.len:d }}")
                            |> koruos/spawn:exec(image_ptr: r.buf.ptr, image_len: r.buf.len, rights: 1152921504606846978)
                                | ok e |> std/io:print.ln("spawn: elf child exited status={{ e:d }}")
                                    |> koruos/ext2:unmount(r.fs)
                                        | ok |> std/io:print.ln("EXT2N COMPLETE")
                                        | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                                | refused e |> std/io:print.ln("FAIL exec: {{ e:s }}") |> koruos/ext2:unmount(r.fs)
                                    | ok |> _
                                    | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                        | refused r |> std/io:print.ln("FAIL read: {{ r.reason:s }}") |> koruos/ext2:unmount(r.fs)
                            | ok |> _
                            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                | mismatch x |> std/io:print.ln("FAIL verify: {{ x.reason:s }}") |> koruos/ext2:unmount(x.fs)
                    | ok |> _
                    | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused r |> std/io:print.ln("FAIL create: {{ r.reason:s }}") |> koruos/ext2:unmount(r.fs)
            | ok |> _
            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
