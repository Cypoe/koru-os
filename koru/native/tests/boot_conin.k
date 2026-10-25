// NATIVE, console-input rung: getc.elf prompts with "?&gt; ", calls
// read(0), and the child goes .blocked on the conin wait key — the only
// thing that resumes it is an 8042 IRQ1 make code pushed through the
// keyboard provider's console ring. A QEMU monitor sendkey is the input;
// serial carries the prompt, the echoed byte, and the exit status.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import std/io

koruos/ext2:mount(id: 0)
| ok m |> koruos/ext2:exec(m.fs, path: "getc.elf", rights: 8070451082021771055)
        | ok e |> std/io:print.ln("conin: exec getc status={{ e.status:d }}")
            |> koruos/ext2:unmount(e.fs)
                | ok |> std/io:print.ln("CONIN COMPLETE")
                | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused e |> std/io:print.ln("FAIL exec getc: {{ e.reason:s }}") |> koruos/ext2:unmount(e.fs)
            | ok |> _
            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
