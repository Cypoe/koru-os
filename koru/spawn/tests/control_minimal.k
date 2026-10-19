// CONTROL: the legal order reserve, grant, seal, start, wait, reap compiles.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/spawn
import std/io

koruos/spawn:authority(spec: "handle console write; spawn census; max_bag 1; max_children 1")
| refused ar |> std/io:print.ln("{{ ar:s }}")
| ok a |> koruos/spawn:reserve(a, image: "census", budget: 4096)
    | refused q |> std/io:print.ln("{{ q.reason:s }}")
    | staged s |> koruos/spawn:grant(c: s, handle: "console", verbs: "write", as: "fd/1")
        | refused r |> koruos/spawn:abandon(r.c)
        | ok g |> koruos/spawn:seal(c: g)
            | refused r |> koruos/spawn:abandon(r.c)
            | sealed z |> koruos/spawn:start(c: z)
                | stalled t |> koruos/spawn:abandon(t.c)
                | running u |> koruos/spawn:wait(c: u): d |> koruos/spawn:reap(d.c)
