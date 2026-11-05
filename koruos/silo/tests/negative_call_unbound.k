// NEGATIVE: call through a handle that was minted but never bound to a row.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/silo
import std/io

koruos/silo:open(name: "n", exports: "blk.read")
| ok s |> koruos/silo:mint(silo: s)
    | ok m |> koruos/silo:call(m.h)
        | dispatched d |> koruos/silo:release(d.h) |> koruos/silo:close(m.silo)
        | revoked v |> koruos/silo:discard(v.h) |> koruos/silo:close(m.silo)
        | refused f |> koruos/silo:discard(f.h) |> koruos/silo:close(m.silo)
    | exhausted x |> koruos/silo:close(silo: x)
| refused why |> std/io:print.ln("{{ why.reason:s }}")
