// HOSTED, ext2 over the file-backed blkdev: the same chain boot_ext2
// proves on koru-native — mount a host-made ext2 image, create /dod1,
// read it back, exec a child ELF, pin it, re-exec by nid — but every
// provider lands on host primitives: KORU_BLK0 is a file, spawn is
// fork+execve, and the nid store persists to $KORU_NID_STORE.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/ext2
import std/io

koruos/ext2:mount(id: 0)
| ok m |> std/io:print.ln("ext2h: mounted blocks={{ m.blocks:d }} free_blocks={{ m.free_blocks:d }} inodes={{ m.inodes:d }} free_inodes={{ m.free_inodes:d }}")
    |> koruos/ext2:create(m.fs, name: "dod1", size: 10000)
        | ok c |> std/io:print.ln("ext2h: created dod1 ino={{ c.ino:d }} blocks={{ c.blocks:d }} first_block={{ c.first_block:d }}")
            |> koruos/ext2:verify(c.fs, path: "dod1", size: 10000)
                | ok v |> std/io:print.ln("ext2h: read back dod1 ino={{ v.ino:d }} bytes={{ v.bytes:d }} content=ok")
                    |> koruos/ext2:exec(v.fs, path: "child.elf", rights: 1152921504606846978)
                        | ok e |> std/io:print.ln("ext2h: exec child.elf ino={{ e.ino:d }} nid={{ e.nid:x }} status={{ e.status:d }}")
                            |> koruos/ext2:pin(e.fs, path: "child.elf")
                                | ok p |> std/io:print.ln("ext2h: pinned child.elf ino={{ p.ino:d }} nid={{ p.nid:x }}")
                                    |> koruos/ext2:exec-by-nid(p.nid, rights: 1152921504606846978)
                                        | ok y |> std/io:print.ln("ext2h: exec-bynid dev={{ y.dev:d }} ino={{ y.ino:d }} status={{ y.status:d }}")
                                            |> koruos/ext2:exec-nid(p.fs, p.nid, rights: 1152921504606846978)
                                                | ok x |> std/io:print.ln("ext2h: exec-nid ino={{ x.ino:d }} status={{ x.status:d }}")
                                                    |> koruos/ext2:unmount(x.fs)
                                                        | ok |> koruos/ext2:exec-by-nid(p.nid, rights: 1152921504606846978)
                                                            | ok w |> std/io:print.ln("FAIL exec-bynid ran post-unmount")
                                                            | refused w |> std/io:print.ln("ext2h: exec-bynid post-unmount refused: {{ w:s }}")
                                                                |> std/io:print.ln("EXT2H COMPLETE")
                                                        | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                                                | refused x |> std/io:print.ln("FAIL exec-nid: {{ x.reason:s }}") |> koruos/ext2:unmount(x.fs)
                                                    | ok |> _
                                                    | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                                        | refused y |> std/io:print.ln("FAIL exec-bynid: {{ y:s }}") |> koruos/ext2:unmount(p.fs)
                                            | ok |> _
                                            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                                | refused p |> std/io:print.ln("FAIL pin: {{ p.reason:s }}") |> koruos/ext2:unmount(p.fs)
                                    | ok |> _
                                    | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                        | refused e |> std/io:print.ln("FAIL exec: {{ e.reason:s }}") |> koruos/ext2:unmount(e.fs)
                            | ok |> _
                            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                | mismatch x |> std/io:print.ln("FAIL verify: {{ x.reason:s }}") |> koruos/ext2:unmount(x.fs)
                    | ok |> _
                    | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused r |> std/io:print.ln("FAIL create: {{ r.reason:s }}") |> koruos/ext2:unmount(r.fs)
            | ok |> _
            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
