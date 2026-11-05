// AUTO-DISCHARGE: a live binding is never released. koruc inserts the release itself (B5
// auto-discharge, as DS0 autodischarge_handle_release.k); it emits it AFTER the explicit
// close, so close reports "LEAK outstanding=1 (table kept)" and does not free the table under
// the binding. Gate: koruc must emit koru_nid.release_event.handler.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/nid
import std/io

koruos/nid:open(manifest: "create c/libc/1/fputs -> koruos.console.write@1 => console_com1_v1:write", nid_bits: 64)
| refused o |> std/io:print.ln("{{ o.reason:s }}")
| ok t |> koruos/nid:resolve(t, foreign: "c/libc/1/fputs")
    | refused u |> koruos/nid:close(u.t)
    | bound r |> koruos/nid:close(r.t)
