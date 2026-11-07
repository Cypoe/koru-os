// NATIVE, busybox-sh-pty rung: an mb2 cpio module carries /bin/ptysh
// (the driver) + /bin/busybox (alpine dynamic 1.37) + ld-musl/libc +
// applet links; the initramfs view mounts it and exec spawns the
// driver under a TIGHT bag — the class set jobctl runs plus the
// loader/fs surface the shell's payload demands (fstat/lseek/mmap/
// mprotect/munmap/brk/nanosleep + the fs-object class). The child's
// SHP lines are the evidence: unmodified ash doing real `&`/`jobs`/
// `fg`/`^Z`/`bg`/`kill %1`/`wait %1`($?=128+15)/`^C` through the
// pty's ldisc — async handler facts pulled through explicit wait,
// per the stored-metadata ruling.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/initramfs
import std/io

std/io:print.ln("shpty: begin")
|> koruos/initramfs:open(module: "shpty.cpio")
| ok o |> koruos/initramfs:exec(o.fs, path: "/bin/ptysh", rights: 8214566321624457007)
    | ok x |> std/io:print.ln("shpty: exec /bin/ptysh ino={{ x.ino:d }} status={{ x.status:d }}")
        |> std/io:print.ln("SHPTY GATE COMPLETE")
    | refused xe |> std/io:print.ln("FAIL exec: {{ xe:s }}")
| refused oe |> std/io:print.ln("FAIL open: {{ oe:s }}")
