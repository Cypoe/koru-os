// POSITIVE, Slice A (DESIGN-0001 §11.4) in a Koru-built Unikraft image.
// Checked by ../../../experiments/slice-a/check.py. Layout at build time
// (experiments/slice-a/build-slice.sh): <root>/koruos/slice/tests/boot_slice.k and
// <root>/unikraft (koru-libs @ ff5cb559). The ART tokens are filled by the build script.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
    unikraft: {{ ENTRY }}/../../../unikraft
}

import unikraft
import koruos/slice
import std/io

unikraft:image(name: "koru") {
    APPKORU_CFLAGS-y += -DKORU_SLICE_A=1
}

unikraft:kconfig {
    CONFIG_OPTIMIZE_SIZE: 'y'
    CONFIG_OPTIMIZE_DEADELIM: 'y'
    CONFIG_LIBUKBOOT_BANNER_NONE: 'y'
    CONFIG_LIBUKDEBUG_ENABLE_ASSERT: 'n'
    CONFIG_LIBUKALLOC: 'y'
    CONFIG_LIBUKALLOCBBUDDY: 'y'
}

std/io:print.ln("slice-a: begin")
|> koruos/slice:census(): r0
|> std/io:print.ln("supervisor: roster={{ r0:d }}")
// (1) only incompatible providers for store.bounded@1: wrong revision, wrong entry size
|> koruos/slice:load(manifest: "name=store_mem_v2,iface=store.bounded,rev=2,layout=x86_64-le-p8,entry=64,effects=mem,artifact=@@ART:store_mem_v1@@; name=store_wide,iface=store.bounded,rev=1,layout=x86_64-le-p8,entry=128,effects=mem,artifact=@@ART:store_mem_v1@@", allow: "@@ART:store_mem_v1@@")
| refused lr |> std/io:print.ln("FAIL manifest1: {{ lr.reason:s }}")
| ok m1 |> koruos/slice:resolve(m: m1, iface: "store.bounded", rev: 1, layout: "x86_64-le-p8", entry: 64, effects: "mem")
    | bound x |> std/io:print.ln("FAIL manifest1 bound") |> koruos/slice:unbind(x.b) |> koruos/slice:close(x.m)
    | refused r1 |> std/io:print.ln("refused: interface={{ r1.iface:s }}@{{ r1.rev:d }} arm={{ r1.arm:s }} phase={{ r1.phase:s }} missing={{ r1.missing:s }} offered=[{{ r1.offered:s }}]")
        |> koruos/slice:close(r1.m)
        // (2) a compatible provider, but its artifact is not authorized
        |> koruos/slice:load(manifest: "name=store_mem_v1,iface=store.bounded,rev=1,layout=x86_64-le-p8,entry=64,effects=mem,artifact=@@ART:store_mem_v1@@", allow: "@@ART:clock_uk_v1@@")
        | refused lr2 |> std/io:print.ln("FAIL manifest2: {{ lr2.reason:s }}")
        | ok m2 |> koruos/slice:resolve(m: m2, iface: "store.bounded", rev: 1, layout: "x86_64-le-p8", entry: 64, effects: "mem")
            | bound x2 |> std/io:print.ln("FAIL manifest2 bound") |> koruos/slice:unbind(x2.b) |> koruos/slice:close(x2.m)
            | refused r2 |> std/io:print.ln("refused: interface={{ r2.iface:s }}@{{ r2.rev:d }} arm={{ r2.arm:s }} phase={{ r2.phase:s }} missing={{ r2.missing:s }} offered=[{{ r2.offered:s }}]")
                |> koruos/slice:close(r2.m)
                // (3) authorized and compatible on paper, but no such artifact is linked here; and a provider with too many effects
                |> koruos/slice:load(manifest: "name=store_ghost,iface=store.bounded,rev=1,layout=x86_64-le-p8,entry=64,effects=mem,artifact=0000000000000000000000000000000000000000000000000000000000000000; name=store_net,iface=store.bounded,rev=1,layout=x86_64-le-p8,entry=64,effects=mem+net,artifact=@@ART:store_mem_v1@@", allow: "0000000000000000000000000000000000000000000000000000000000000000,@@ART:store_mem_v1@@")
                | refused lr3 |> std/io:print.ln("FAIL manifest3: {{ lr3.reason:s }}")
                | ok m3 |> koruos/slice:resolve(m: m3, iface: "store.bounded", rev: 1, layout: "x86_64-le-p8", entry: 64, effects: "mem")
                    | bound x3 |> std/io:print.ln("FAIL manifest3 bound") |> koruos/slice:unbind(x3.b) |> koruos/slice:close(x3.m)
                    | refused r3 |> std/io:print.ln("refused: interface={{ r3.iface:s }}@{{ r3.rev:d }} arm={{ r3.arm:s }} phase={{ r3.phase:s }} missing={{ r3.missing:s }} offered=[{{ r3.offered:s }}]")
                        |> koruos/slice:close(r3.m)
                        |> koruos/slice:census(): r1c
                        |> std/io:print.ln("supervisor: roster={{ r1c:d }} after refusals")
                        // (4) the good manifest: incompatible candidates first, then the authorized one
                        |> koruos/slice:load(manifest: "name=store_mem_v2,iface=store.bounded,rev=2,layout=x86_64-le-p8,entry=64,effects=mem,artifact=@@ART:store_mem_v1@@; name=store_wide,iface=store.bounded,rev=1,layout=x86_64-le-p8,entry=128,effects=mem,artifact=@@ART:store_mem_v1@@; name=store_mem_v1,iface=store.bounded,rev=1,layout=x86_64-le-p8,entry=64,effects=mem,artifact=@@ART:store_mem_v1@@; name=clock_uk_v1,iface=clock.tick,rev=1,layout=x86_64-le-p8,entry=0,effects=clock,artifact=@@ART:clock_uk_v1@@; name=view_debugcon_v1,iface=view.status,rev=1,layout=x86_64-le-p8,entry=0,effects=io.debugcon,artifact=@@ART:view_debugcon_v1@@", allow: "@@ART:store_mem_v1@@,@@ART:clock_uk_v1@@,@@ART:view_debugcon_v1@@")
                        | refused lr4 |> std/io:print.ln("FAIL manifest4: {{ lr4.reason:s }}")
                        | ok m4 |> koruos/slice:resolve(m: m4, iface: "store.bounded", rev: 1, layout: "x86_64-le-p8", entry: 64, effects: "mem")
                            | refused r4 |> std/io:print.ln("FAIL store refused: {{ r4.offered:s }}") |> koruos/slice:close(r4.m)
                            | bound s |> koruos/slice:resolve(s.m, iface: "clock.tick", rev: 1, layout: "x86_64-le-p8", entry: 0, effects: "clock")
                                | refused r5 |> std/io:print.ln("FAIL clock refused: {{ r5.offered:s }}") |> koruos/slice:unbind(s.b) |> koruos/slice:close(r5.m)
                                | bound c |> koruos/slice:resolve(c.m, iface: "view.status", rev: 1, layout: "x86_64-le-p8", entry: 0, effects: "io.debugcon")
                                    | refused r6 |> std/io:print.ln("FAIL view refused: {{ r6.offered:s }}") |> koruos/slice:unbind(s.b) |> koruos/slice:unbind(c.b) |> koruos/slice:close(r6.m)
                                    | bound v |> koruos/slice:close(v.m)
                                        // a child whose bag lacks what its image requires is refused at seal
                                        |> koruos/slice:reserve(image: "slice-a-task", artifact: "@@ART:slice_task@@", budget: 4096)
                                        | refused rr |> std/io:print.ln("FAIL reserve: {{ rr:s }}") |> koruos/slice:unbind(s.b) |> koruos/slice:unbind(c.b) |> koruos/slice:unbind(v.b)
                                        | staged k0 |> koruos/slice:seal(c: k0, requires: "store,clock,view")
                                            | sealed k0s |> std/io:print.ln("FAIL empty bag sealed") |> koruos/slice:abandon(c: k0s) |> koruos/slice:unbind(s.b) |> koruos/slice:unbind(c.b) |> koruos/slice:unbind(v.b)
                                            | refused k0r |> koruos/slice:abandon(k0r.c)
                                                |> koruos/slice:reserve(image: "slice-a-task", artifact: "@@ART:slice_task@@", budget: 4096)
                                                | refused rr2 |> std/io:print.ln("FAIL reserve: {{ rr2:s }}") |> koruos/slice:unbind(s.b) |> koruos/slice:unbind(c.b) |> koruos/slice:unbind(v.b)
                                                | staged k |> koruos/slice:grant(c: k, s.b, as: "store"): g1
                                                    |> koruos/slice:grant(c: g1, c.b, as: "clock"): g2
                                                    |> koruos/slice:grant(c: g2, v.b, as: "view"): g3
                                                    |> koruos/slice:seal(c: g3, requires: "store,clock,view")
                                                    | refused kr |> std/io:print.ln("FAIL seal: {{ kr.missing:s }}") |> koruos/slice:abandon(kr.c)
                                                    | sealed ks |> koruos/slice:start(c: ks)
                                                        | stalled st |> std/io:print.ln("FAIL start: {{ st.reason:s }}") |> koruos/slice:abandon(st.c)
                                                        | running kr2 |> koruos/slice:census(): r2c
                                                            |> std/io:print.ln("supervisor: roster={{ r2c:d }} while running")
                                                            |> koruos/slice:wait(c: kr2): done
                                                            |> koruos/slice:reap(done.c)
                                                            |> koruos/slice:census(): r3c
                                                            |> std/io:print.ln("supervisor: roster={{ r3c:d }} after reap; status={{ done.status:d }} ticks={{ done.ticks:d }}")
                                                            |> std/io:print.ln("slice-a: end")
