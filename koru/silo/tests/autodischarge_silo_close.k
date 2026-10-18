// AUTO-DISCHARGE (compiles by design): <open!> has exactly one disposal (close), so koruc inserts it. check-negatives.sh asserts the emitted close call.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/silo
import std/io

koruos/silo:open(name: "n", exports: "blk.read")
| ok s |> koruos/silo:mint(silo: s)
    | ok m |> koruos/silo:release(m.h)
    | exhausted x |> koruos/silo:close(silo: x)
| refused why |> std/io:print.ln("{{ why.reason:s }}")
