// NATIVE, ext2 over our own virtio-blk: mount a host-made ext2 image on
// koru-native, create /dod1, read it back, then ext2:exec — one provider
// call folding path walk → inode identity → ELF load → ring-3 spawn —
// then unmount, on a substrate that owns the device itself.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import std/io

// ext2:exec / ext2:pin bind ext2/d0/<ino> identities into koruos/nid's
// object-pin store — on koru-native the store is provided by the native
// runtime (koruos_nid_obj_*); arms without it refuse at link, by name.
koruos/ext2:mount(id: 0)
| ok m |> std/io:print.ln("ext2n: mounted blocks={{ m.blocks:d }} free_blocks={{ m.free_blocks:d }} inodes={{ m.inodes:d }} free_inodes={{ m.free_inodes:d }}")
    |> koruos/ext2:create(m.fs, name: "dod1", size: 10000)
        | ok c |> std/io:print.ln("ext2n: created dod1 ino={{ c.ino:d }} blocks={{ c.blocks:d }} first_block={{ c.first_block:d }}")
            |> koruos/ext2:verify(c.fs, path: "dod1", size: 10000)
                | ok v |> std/io:print.ln("ext2n: read back dod1 ino={{ v.ino:d }} bytes={{ v.bytes:d }} content=ok")
                    |> koruos/ext2:exec(v.fs, path: "child.elf", rights: 1152921504606846978)
                        | ok e |> std/io:print.ln("ext2n: exec child.elf ino={{ e.ino:d }} nid={{ e.nid:x }} status={{ e.status:d }}")
                            |> koruos/ext2:pin(e.fs, path: "child.elf")
                                | ok p |> std/io:print.ln("ext2n: pinned child.elf ino={{ p.ino:d }} nid={{ p.nid:x }}")
                                    |> koruos/ext2:exec-by-nid(p.nid, rights: 1152921504606846978)
                                        | ok y |> std/io:print.ln("ext2n: exec-bynid dev={{ y.dev:d }} ino={{ y.ino:d }} status={{ y.status:d }}")
                                            |> koruos/ext2:exec-nid(p.fs, p.nid, rights: 1152921504606846978)
                                                | ok x |> std/io:print.ln("ext2n: exec-nid ino={{ x.ino:d }} status={{ x.status:d }}")
                                                    |> koruos/ext2:unmount(x.fs)
                                                        | ok |> koruos/ext2:exec-by-nid(p.nid, rights: 1152921504606846978)
                                                            | ok w |> std/io:print.ln("FAIL exec-bynid ran post-unmount")
                                                            | refused w |> std/io:print.ln("ext2n: exec-bynid post-unmount refused: {{ w:s }}")
                                                                |> std/io:print.ln("EXT2N COMPLETE")
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
