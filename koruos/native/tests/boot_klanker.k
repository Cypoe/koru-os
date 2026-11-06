// NATIVE, klanker-child: an mb2 cpio module carries a REAL
// CPython 3.12 (alpine/musl, PIE + ld-musl PT_INTERP) plus a measured
// stdlib subset, /bin/pyrun — the musl stub that execve()s
// /usr/bin/python3 -S /main.py through the exec-verb arm — and
// klanker + agents-* sources flattened into the stdlib dir (-S skips
// site.py's hook). The bag is deliberately generous-but-named
// (io/fs/channel/sleep/proc/create/exit/wait classes): every KL line
// is a syscall surface klanker proved; every SEAM REFUSE or traceback
// is the rung's named gap — that list IS the deliverable.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/initramfs
import std/io

std/io:print.ln("py: begin")
|> koruos/initramfs:open(module: "kroot.cpio")
| ok o |> koruos/initramfs:exec(o.fs, path: "/bin/pyrun", rights: 8214566304453631791)
    | ok x |> std/io:print.ln("py: exec /bin/pyrun ino={{ x.ino:d }} status={{ x.status:d }}")
        |> std/io:print.ln("PY GATE COMPLETE")
    | refused xe |> std/io:print.ln("FAIL exec: {{ xe:s }}")
| refused oe |> std/io:print.ln("FAIL open: {{ oe:s }}")
