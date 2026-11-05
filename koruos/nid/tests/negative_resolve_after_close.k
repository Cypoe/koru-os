// NEGATIVE: resolves against a table after closing it. Must be rejected at compile time.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/nid
import std/io

koruos/nid:open(manifest: "create c/libc/1/fputs -> koruos.console.write@1 => console_com1_v1:write", nid_bits: 64)
| refused o |> std/io:print.ln("{{ o.reason:s }}")
| ok t |> koruos/nid:close(t) |> koruos/nid:resolve(t, foreign: "c/libc/1/fputs")
    | refused u |> koruos/nid:close(u.t)
    | bound r |> koruos/nid:release(r.b) |> koruos/nid:close(r.t)
