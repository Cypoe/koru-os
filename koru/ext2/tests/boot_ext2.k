// POSITIVE, M2 (DoD-1): create /dod1 on a host-made ext2 image over virtio-blk,
// read it back in the guest; the host then runs e2fsck -fn and debugfs.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
    unikraft: {{ ENTRY }}/../../../unikraft
}

import unikraft
import koruos/ext2
import std/io

unikraft:image(name: "koru") {
    APPKORU_CFLAGS-y += -DKORU_M2=1
}

unikraft:kconfig {
    CONFIG_OPTIMIZE_SIZE: 'y'
    CONFIG_OPTIMIZE_DEADELIM: 'y'
    CONFIG_LIBUKBOOT_BANNER_NONE: 'y'
    CONFIG_LIBUKDEBUG_ENABLE_ASSERT: 'n'
    CONFIG_LIBUKALLOC: 'y'
    CONFIG_LIBUKALLOCBBUDDY: 'y'
    CONFIG_LIBUKBLKDEV: 'y'
    CONFIG_LIBVIRTIO_BLK: 'y'
    CONFIG_LIBVIRTIO_PCI: 'y'
    CONFIG_LIBVIRTIO_BUS: 'y'
}

koruos/ext2:mount(id: 0)
| ok m |> std/io:print.ln("ext2: mounted blocks={{ m.blocks:d }} free_blocks={{ m.free_blocks:d }} inodes={{ m.inodes:d }} free_inodes={{ m.free_inodes:d }}")
    |> koruos/ext2:create(m.fs, name: "dod1", size: 10000)
        | ok c |> std/io:print.ln("ext2: created dod1 ino={{ c.ino:d }} blocks={{ c.blocks:d }} first_block={{ c.first_block:d }}")
            |> koruos/ext2:verify(c.fs, name: "dod1", size: 10000)
                | ok v |> std/io:print.ln("ext2: read back dod1 ino={{ v.ino:d }} bytes={{ v.bytes:d }} content=ok")
                    |> koruos/ext2:unmount(v.fs)
                        | ok |> std/io:print.ln("M2 guest: complete")
                        | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                | mismatch x |> std/io:print.ln("FAIL verify: {{ x.reason:s }}") |> koruos/ext2:unmount(x.fs)
                    | ok |> _
                    | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused r |> std/io:print.ln("FAIL create: {{ r.reason:s }}") |> koruos/ext2:unmount(r.fs)
            | ok |> _
            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
