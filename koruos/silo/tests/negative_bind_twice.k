// NEGATIVE: bind an already-bound handle to a second row.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/silo
import std/io

koruos/silo:open(name: "n", exports: "blk.read,blk.info")
| ok s |> koruos/silo:mint(silo: s)
    | ok m |> koruos/silo:bind(m.h, row: "blk.read")
        | ok b |> koruos/silo:bind(h: b, row: "blk.info")
            | ok b2 |> koruos/silo:release(h: b2) |> koruos/silo:close(m.silo)
            | refused r |> koruos/silo:release(r.h) |> koruos/silo:close(m.silo)
        | refused r |> koruos/silo:release(r.h) |> koruos/silo:close(m.silo)
    | exhausted x |> koruos/silo:close(silo: x)
| refused why |> std/io:print.ln("{{ why.reason:s }}")
