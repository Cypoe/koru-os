// boot_fb — pins that the fb seam reports real geometry and that drawing is
// admitted or refused by branch, not by side effect. The visible artifact
// (a three-band screen) is human evidence; the serial lines are the gate.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/fb
import std/io

koruos/fb:info()
| ok i |> std/io:print.ln("fb: {{ i.width:d }}x{{ i.height:d }} pitch={{ i.pitch:d }} bpp={{ i.bpp:d }}")
    |> koruos/fb:fill(x: 0, y: 0, w: i.width, h: i.height / 3, color: 0x00FF0000)
        | ok |> koruos/fb:fill(x: 0, y: i.height / 3, w: i.width, h: i.height / 3, color: 0x0000FF00)
            | ok |> koruos/fb:fill(x: 0, y: 2 * i.height / 3, w: i.width, h: i.height - 2 * i.height / 3, color: 0x000000FF)
                | ok |> std/io:print.ln("FB COMPLETE")
                | absent m |> std/io:print.ln("FAIL fill3: {{ m:s }}")
            | absent m |> std/io:print.ln("FAIL fill2: {{ m:s }}")
        | absent m |> std/io:print.ln("FAIL fill1: {{ m:s }}")
| absent m |> std/io:print.ln("fb absent: {{ m:s }}")
