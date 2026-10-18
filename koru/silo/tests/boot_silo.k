// POSITIVE, DS0 in a unikernel: the silo membrane, driven from Koru, inside a
// Koru-built Unikraft image. Every line it prints is checked by ../../../experiments/ds0-silo/run-image.sh.
//
// Layout at build time (see build-image.sh): <root>/koruos/silo/tests/boot_silo.k
// and <root>/unikraft (koru-libs @ ff5cb559).
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
    unikraft: {{ ENTRY }}/../../../unikraft
}

import unikraft
import koruos/silo
import std/io

unikraft:image(name: "koru") {
    APPKORU_CFLAGS-y += -DKORU_DS0=1
}

unikraft:kconfig {
    CONFIG_OPTIMIZE_SIZE: 'y'
    CONFIG_OPTIMIZE_DEADELIM: 'y'
    CONFIG_LIBUKBOOT_BANNER_NONE: 'y'
    CONFIG_LIBUKDEBUG_ENABLE_ASSERT: 'n'
    CONFIG_LIBUKALLOC: 'y'
    CONFIG_LIBUKALLOCBBUDDY: 'y'
}

koruos/silo:open(name: "empty0", exports: "")
| ok e |> koruos/silo:mint(silo: e)
    | ok m |> koruos/silo:bind(m.h, row: "blk.read")
        | ok b |> std/io:print.ln("FAIL empty0 bound blk.read") |> koruos/silo:release(h: b)
        | refused r |> std/io:print.ln("refused: {{ r.row:s }} silo={{ r.silo:s }} reason={{ r.reason:s }}")
            |> koruos/silo:bind(r.h, row: "kms.atomic")
                | ok b |> std/io:print.ln("FAIL empty0 bound kms.atomic") |> koruos/silo:release(h: b)
                | refused r2 |> std/io:print.ln("refused: {{ r2.row:s }} silo={{ r2.silo:s }} reason={{ r2.reason:s }}")
                    |> koruos/silo:bind(r2.h, row: "linux.sys.mount")
                        | ok b |> std/io:print.ln("FAIL empty0 bound linux.sys.mount") |> koruos/silo:release(h: b)
                        | refused r3 |> std/io:print.ln("refused: {{ r3.row:s }} silo={{ r3.silo:s }} reason={{ r3.reason:s }}")
                            |> koruos/silo:release(r3.h)
                            |> koruos/silo:stats(m.silo): st
                            |> std/io:print.ln("empty0: refusals={{ st.refusals:d }} dispatches={{ st.dispatches:d }}")
                            |> koruos/silo:close(st.silo)
                            |> koruos/silo:open(name: "bad0", exports: "blk.read,linux.sys.mount")
                                | ok bad |> std/io:print.ln("FAIL bad0 manifest accepted") |> koruos/silo:close(silo: bad)
                                | refused why |> std/io:print.ln("refused: manifest silo=bad0 row={{ why.row:s }} reason={{ why.reason:s }}")
                                    |> koruos/silo:open(name: "blk0", exports: "blk.info,blk.read")
                                        | ok s |> koruos/silo:mint(silo: s)
                                            | ok m1 |> koruos/silo:bind(m1.h, row: "blk.read")
                                                | ok b1 |> koruos/silo:call(h: b1)
                                                    | dispatched d |> std/io:print.ln("dispatched: {{ d.row:s }} silo=blk0")
                                                        |> koruos/silo:tamper(d.h): t
                                                        |> koruos/silo:call(h: t)
                                                            | dispatched d2 |> std/io:print.ln("FAIL forged handle dispatched") |> koruos/silo:release(d2.h)
                                                            | revoked v |> std/io:print.ln("FAIL forged handle reported revoked") |> koruos/silo:discard(v.h)
                                                            | refused f |> std/io:print.ln("refused: {{ f.row:s }} silo={{ f.silo:s }} reason={{ f.reason:s }}")
                                                                |> koruos/silo:discard(f.h)
                                                                |> koruos/silo:mint(m1.silo)
                                                                    | ok m2 |> koruos/silo:bind(m2.h, row: "blk.info")
                                                                        | ok b2 |> koruos/silo:restart(m2.silo): s2
                                                                            |> koruos/silo:call(h: b2)
                                                                                | dispatched d3 |> std/io:print.ln("FAIL stale handle dispatched") |> koruos/silo:release(d3.h) |> koruos/silo:close(silo: s2)
                                                                                | refused f3 |> std/io:print.ln("FAIL stale handle refused as {{ f3.reason:s }}") |> koruos/silo:discard(f3.h) |> koruos/silo:close(silo: s2)
                                                                                | revoked v3 |> std/io:print.ln("revoked: {{ v3.row:s }} silo={{ v3.silo:s }} reason=epoch")
                                                                                    |> koruos/silo:discard(v3.h)
                                                                                    |> koruos/silo:stats(silo: s2): st2
                                                                                    |> std/io:print.ln("blk0: refusals={{ st2.refusals:d }} dispatches={{ st2.dispatches:d }} epoch={{ st2.epoch:d }}")
                                                                                    |> koruos/silo:close(st2.silo)
                                                                                    |> std/io:print.ln("DS0 image: complete")
                                                                        | refused r4 |> std/io:print.ln("FAIL bind blk.info: {{ r4.reason:s }}") |> koruos/silo:release(r4.h) |> koruos/silo:close(m2.silo)
                                                                    | exhausted x |> koruos/silo:close(silo: x)
                                                    | revoked v |> std/io:print.ln("FAIL fresh handle revoked") |> koruos/silo:discard(v.h) |> koruos/silo:close(m1.silo)
                                                    | refused f |> std/io:print.ln("FAIL fresh handle refused: {{ f.reason:s }}") |> koruos/silo:discard(f.h) |> koruos/silo:close(m1.silo)
                                                | refused r5 |> std/io:print.ln("FAIL bind blk.read: {{ r5.reason:s }}") |> koruos/silo:release(r5.h) |> koruos/silo:close(m1.silo)
                                            | exhausted x |> koruos/silo:close(silo: x)
                                        | refused why2 |> std/io:print.ln("FAIL open blk0: {{ why2.reason:s }}")
    | exhausted x |> koruos/silo:close(silo: x)
| refused why |> std/io:print.ln("FAIL open empty0: {{ why.reason:s }}")
