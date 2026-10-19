// NEGATIVE: add a grant to a child whose bag is already sealed.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/slice
import std/io

koruos/slice:load(manifest: "name=c,iface=clock.tick,rev=1,layout=x86_64-le-p8,entry=0,effects=clock,artifact=a", allow: "a")
| refused lr |> std/io:print.ln("{{ lr.reason:s }}")
| ok m |> koruos/slice:resolve(m, iface: "clock.tick", rev: 1, layout: "x86_64-le-p8", entry: 0, effects: "clock")
    | refused r |> koruos/slice:close(r.m)
    | bound b |> koruos/slice:close(b.m)
        |> koruos/slice:reserve(image: "t", artifact: "a", budget: 4096)
        | refused rr |> std/io:print.ln("{{ rr:s }}") |> koruos/slice:unbind(b.b)
        | staged k |> koruos/slice:seal(c: k, requires: "")
            | refused kr |> koruos/slice:abandon(kr.c) |> koruos/slice:unbind(b.b)
            | sealed ks |> koruos/slice:grant(c: ks, b.b, as: "clock"): g |> koruos/slice:abandon(c: g)
