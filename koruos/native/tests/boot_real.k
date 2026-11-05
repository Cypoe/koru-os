// NATIVE, real-ELF rung: mount ext2 on our own virtio-blk, then exec
// pie.elf — a real gcc -static-pie binary (ET_DYN): the loader applies
// the load bias, maps through the multi-pt user space, builds the real
// initial stack, and the child writes + exit_groups through the seam.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import std/io

koruos/ext2:mount(id: 0)
| ok m |> koruos/ext2:exec(m.fs, path: "pie.elf", rights: 1152921504606846978)
        | ok e |> std/io:print.ln("real: exec pie.elf ino={{ e.ino:d }} nid={{ e.nid:x }} status={{ e.status:d }}")
            |> koruos/ext2:exec(e.fs, path: "musl.elf", rights: 8070450532249047554)
                | ok x |> std/io:print.ln("real: exec musl.elf status={{ x.status:d }}")
                    |> koruos/ext2:exec(x.fs, path: "fscat.elf", rights: 8070450532249178927)
                        | ok q |> std/io:print.ln("real: exec fscat.elf status={{ q.status:d }}")
                            |> koruos/ext2:exec(q.fs, path: "bin/hi.elf", rights: 18446744073709551615)
                                | ok h |> std/io:print.ln("real: exec hi.elf status={{ h.status:d }}")
                                    |> koruos/ext2:exec(h.fs, path: "bin/busybox", rights: 18446744073709551615)
                                        | ok b |> std/io:print.ln("real: exec busybox status={{ b.status:d }}")
                                            |> koruos/ext2:exec(b.fs, path: "bin/uname", rights: 17293823118859771695)
                                                | ok u |> std/io:print.ln("real: exec uname status={{ u.status:d }}")
                                                    |> koruos/ext2:unmount(u.fs)
                                                        | ok |> std/io:print.ln("REALELF COMPLETE")
                                                        | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                                                | refused u |> std/io:print.ln("FAIL exec uname: {{ u.reason:s }}") |> koruos/ext2:unmount(u.fs)
                                                    | ok |> _
                                                    | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                                        | refused b |> std/io:print.ln("FAIL exec busybox: {{ b.reason:s }}") |> koruos/ext2:unmount(b.fs)
                                            | ok |> _
                                            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                                | refused h |> std/io:print.ln("FAIL exec hi: {{ h.reason:s }}") |> koruos/ext2:unmount(h.fs)
                                    | ok |> _
                                    | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                        | refused q |> std/io:print.ln("FAIL exec fscat: {{ q.reason:s }}") |> koruos/ext2:unmount(q.fs)
                            | ok |> _
                            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
                | refused x |> std/io:print.ln("FAIL exec musl: {{ x.reason:s }}") |> koruos/ext2:unmount(x.fs)
                    | ok |> _
                    | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused e |> std/io:print.ln("FAIL exec: {{ e.reason:s }}") |> koruos/ext2:unmount(e.fs)
            | ok |> _
            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
