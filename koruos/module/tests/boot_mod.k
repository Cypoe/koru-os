// NATIVE, module rung: GRUB's `module` files arrive as mb2 tag-3
// payloads — pmm reserves their pages, koruos/module enumerates the
// table and execs the payload ELF as a real CPL=3 child (own CR3, no
// fs view — open() is ENOSYS inside it, honestly). The ISO carries
// musl.elf as the module; the child's own "musl child says hi" and its
// exit status are the evidence, not the parent's claim.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/module
import std/io

std/io:print.ln("mod: begin")
|> koruos/module:modules()
| absent m |> std/io:print.ln("FAIL modules: {{ m:s }}")
| ok n |> std/io:print.ln("mod: count={{ n:d }}")
    |> koruos/module:exec(name: "musl-mod.elf", rights: 18446744073709551615)
    | refused e |> std/io:print.ln("FAIL exec: {{ e:s }}")
    | ok st |> std/io:print.ln("mod: exec status={{ st:d }}")
        |> std/io:print.ln("MODEXEC COMPLETE")
