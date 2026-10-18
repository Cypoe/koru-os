// CONTROL (positive): the smallest correct use; must compile, so the negatives
// above fail for their stated reason and not for a harness problem.
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
            | revoked v |> koruos/silo:discard(v.h) |> koruos/silo:close(m.silo)
            | refused f |> koruos/silo:discard(f.h) |> koruos/silo:close(m.silo)
        | refused r |> koruos/silo:release(r.h) |> koruos/silo:close(m.silo)
    | exhausted x |> koruos/silo:close(silo: x)
| refused why |> std/io:print.ln("{{ why.reason:s }}")
