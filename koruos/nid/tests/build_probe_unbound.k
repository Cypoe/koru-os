// BUILD CONTROL (optional lookup): probe of a name with no row is NOT a build refusal; realize
// gen accepts and predicts the run-time refusal.
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

koruos/nid:open(manifest: "create c/libc/1/fputs -> koruos.console.write@1 => console_com1_v1:write", nid_bits: 64)
| refused o |> std/io:print.ln("{{ o.reason:s }}")
| ok t |> koruos/nid:probe(t, foreign: "c/libc/1/puts")
    | refused u |> koruos/nid:close(u.t)
    | bound r |> koruos/nid:release(r.b) |> koruos/nid:close(r.t)
