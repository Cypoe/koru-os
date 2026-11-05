// NATIVE, initramfs rung: a cpio-newc archive arrives as an mb2 module
// (GRUB module2), koruos/initramfs unpacks it into a RAM-backed
// ChildFsOps view — file bytes point into the pmm-reserved module,
// zero copy — and exec spawns /bin/fsread as a real CPL=3 child whose
// open/read/close resolve THROUGH the view: plain file, symlink,
// hardlink alias, synthesized parent dir. The child's own FSREAD
// lines and exit status are the evidence.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/initramfs
import std/io

std/io:print.ln("ramfs: begin")
|> koruos/initramfs:open(module: "initramfs.cpio")
| ok o |> std/io:print.ln("ramfs: entries={{ o.entries:d }}")
    |> koruos/initramfs:stat(o.fs, path: "/hello.txt")
        | ok s1 |> std/io:print.ln("ramfs: /hello.txt ino={{ s1.ino:d }} mode={{ s1.mode:x }} size={{ s1.size:d }} nlink={{ s1.nlink:d }}")
            |> koruos/initramfs:stat(s1.fs, path: "/etc")
                | ok s2 |> std/io:print.ln("ramfs: /etc (synthesized) ino={{ s2.ino:d }} mode={{ s2.mode:x }}")
                    |> koruos/initramfs:lookup(s2.fs, path: "/link.txt")
                        | ok l1 |> std/io:print.ln("ramfs: /link.txt -> ino={{ l1.ino:d }} (hello ino={{ s1.ino:d }})")
                            |> koruos/initramfs:lookup(l1.fs, path: "/hello2.txt")
                                | ok l2 |> std/io:print.ln("ramfs: /hello2.txt hardlink ino={{ l2.ino:d }} (hello ino={{ s1.ino:d }} — gate compares)")
                                    |> koruos/initramfs:read(l2.fs, path: "/etc/motd.txt")
                                        | ok r1 |> std/io:print.ln("ramfs: /etc/motd.txt bytes={{ r1.buf.len:d }}")
                                            |> koruos/initramfs:exec(r1.fs, path: "/bin/fsread", rights: 18446744073709551615)
                                                | ok x |> std/io:print.ln("ramfs: exec /bin/fsread ino={{ x.ino:d }} status={{ x.status:d }}")
                                                    |> std/io:print.ln("RAMFS COMPLETE")
                                                | refused xe |> std/io:print.ln("FAIL exec: {{ xe:s }}")
                                        | refused re |> std/io:print.ln("FAIL read: {{ re:s }}")
                                | refused l2e |> std/io:print.ln("FAIL lookup hardlink: {{ l2e:s }}")
                        | refused l1e |> std/io:print.ln("FAIL lookup link: {{ l1e:s }}")
                | refused s2e |> std/io:print.ln("FAIL stat /etc: {{ s2e:s }}")
        | refused s1e |> std/io:print.ln("FAIL stat hello: {{ s1e:s }}")
| refused oe |> std/io:print.ln("FAIL open: {{ oe:s }}")
