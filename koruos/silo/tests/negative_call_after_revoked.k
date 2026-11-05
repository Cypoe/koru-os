// NEGATIVE: keep calling through a handle the membrane reported as revoked.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/silo
import std/io

koruos/silo:open(name: "n", exports: "blk.read")
| ok s |> koruos/silo:mint(silo: s)
    | ok m |> koruos/silo:bind(m.h, row: "blk.read")
        | ok b |> koruos/silo:call(h: b)
            | dispatched d |> koruos/silo:release(d.h) |> koruos/silo:close(m.silo)
            | revoked v |> koruos/silo:call(v.h)
                | dispatched d |> koruos/silo:release(d.h) |> koruos/silo:close(m.silo)
                | revoked v2 |> koruos/silo:discard(v2.h) |> koruos/silo:close(m.silo)
                | refused f |> koruos/silo:discard(f.h) |> koruos/silo:close(m.silo)
            | refused f |> koruos/silo:discard(f.h) |> koruos/silo:close(m.silo)
        | refused r |> koruos/silo:release(r.h) |> koruos/silo:close(m.silo)
    | exhausted x |> koruos/silo:close(silo: x)
| refused why |> std/io:print.ln("{{ why.reason:s }}")
