// AUTO-DISCHARGE (compiles by design): <minted!> has exactly one non-reminting disposal (release), so koruc inserts it. check-negatives.sh asserts the emitted release call.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/silo
import std/io

koruos/silo:open(name: "n", exports: "blk.read")
| ok s |> koruos/silo:mint(silo: s)
    | ok m |> koruos/silo:close(m.silo)
    | exhausted x |> koruos/silo:close(silo: x)
| refused why |> std/io:print.ln("{{ why.reason:s }}")
