// BUILD NEGATIVE: with 4-bit NIDs, c/t/1/g31 collides with the row for c/t/1/f00; the required import is refused.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
    unikraft: {{ ENTRY }}/../../../unikraft
}

import unikraft
import koruos/realize
import koruos/nid
import std/io

unikraft:image(name: "koru") {
    APPKORU_CFLAGS-y += -DKORU_NID=1
}

koruos/nid:open(manifest: "create c/t/1/f00 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f01 -> koruos.clock.monotonic@1 => clock_uk_v1:now", nid_bits: 4)
| refused o |> std/io:print.ln("{{ o.reason:s }}")
| ok t |> koruos/nid:resolve(t, foreign: "c/t/1/g31")
    | refused u |> koruos/nid:close(u.t)
    | bound r |> koruos/nid:call(r.b, arg: "x")
        | stale s |> koruos/nid:release(s.b) |> koruos/nid:close(r.t)
        | ok c |> koruos/nid:release(c.b) |> koruos/nid:close(r.t)
