// NEGATIVE: start a child that was never sealed (bag not frozen, imports not checked).
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/slice
import std/io

koruos/slice:reserve(image: "t", artifact: "a", budget: 4096)
| refused r |> std/io:print.ln("{{ r:s }}")
| staged k |> koruos/slice:start(c: k)
    | running x |> koruos/slice:wait(c: x): d |> koruos/slice:reap(d.c)
    | stalled s |> koruos/slice:abandon(s.c)
