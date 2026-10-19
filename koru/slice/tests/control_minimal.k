// CONTROL: the same chain as the negatives, in the legal order; must compile.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/slice
import std/io

koruos/slice:reserve(image: "t", artifact: "a", budget: 4096)
| refused r |> std/io:print.ln("{{ r:s }}")
| staged k |> koruos/slice:seal(c: k, requires: "")
    | refused kr |> koruos/slice:abandon(kr.c)
    | sealed ks |> koruos/slice:start(c: ks)
        | stalled s |> koruos/slice:abandon(s.c)
        | running x |> koruos/slice:wait(c: x): d |> koruos/slice:reap(d.c)
