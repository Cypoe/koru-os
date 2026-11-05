// POSITIVE, the dissected Spawn skeleton (DESIGN-0001 §8.6) in a Koru-built Unikraft image.
// Checked by ../../../experiments/spawn/check.py. Layout at build time
// (experiments/spawn/build-spawn.sh): <root>/koruos/spawn/tests/boot_spawn.k and
// <root>/unikraft (koru-libs @ ff5cb559). Kconfig derived by koruos/realize.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
    unikraft: {{ ENTRY }}/../../../unikraft
}

import unikraft
import koruos/realize
import koruos/spawn
import std/io

unikraft:image(name: "koru") {
    APPKORU_CFLAGS-y += -DKORU_SPAWN=1
}

unikraft:kconfig {
    CONFIG_OPTIMIZE_SIZE: 'y'
    CONFIG_OPTIMIZE_DEADELIM: 'y'
    CONFIG_LIBUKBOOT_BANNER_NONE: 'y'
    CONFIG_LIBUKDEBUG_ENABLE_ASSERT: 'n'
}

std/io:print.ln("spawn: begin")
|> koruos/spawn:census(): r0
|> std/io:print.ln("roster: {{ r0:d }}")
|> koruos/spawn:authority(spec: "handle console write; handle env.TERM read xterm-256color; spawn census|greedy|inert; max_bag 2; max_children 2")
| refused ar |> std/io:print.ln("FAIL authority: {{ ar:s }}")
| ok a |> koruos/spawn:fork(a): fr
    |> std/io:print.ln("fork: {{ fr:s }}")
    |> koruos/spawn:reserve(a, image: "@caller", budget: 4096)
    | staged x |> std/io:print.ln("FAIL reserved @caller") |> koruos/spawn:abandon(c: x)
    | refused q1 |> std/io:print.ln("reserve1: refused reason={{ q1.reason:s }}")
        |> koruos/spawn:reserve(a, image: "evil", budget: 4096)
        | staged x |> std/io:print.ln("FAIL reserved evil") |> koruos/spawn:abandon(c: x)
        | refused q2 |> std/io:print.ln("reserve2: refused reason={{ q2.reason:s }}")
            // (E) a child with an empty bag
            |> koruos/spawn:reserve(a, image: "census", budget: 4096)
            | refused x |> std/io:print.ln("FAIL reserve E: {{ x.reason:s }}")
            | staged e |> koruos/spawn:census(): r1
                |> std/io:print.ln("roster: {{ r1:d }}")
                |> koruos/spawn:seal(c: e)
                | refused x |> std/io:print.ln("FAIL seal E: {{ x.missing:s }}") |> koruos/spawn:abandon(x.c)
                | sealed es |> koruos/spawn:start(c: es)
                    | stalled x |> std/io:print.ln("FAIL start E: {{ x.reason:s }}") |> koruos/spawn:abandon(x.c)
                    | running er |> koruos/spawn:wait(c: er): ew
                        |> std/io:print.ln("E: status={{ ew.status:d }}")
                        |> koruos/spawn:reap(ew.c)
                        |> koruos/spawn:census(): r2
                        |> std/io:print.ln("roster: {{ r2:d }}")
                        // (G) explicit grants, and every refused grant
                        |> koruos/spawn:reserve(a, image: "census", budget: 4096)
                        | refused x |> std/io:print.ln("FAIL reserve G: {{ x.reason:s }}")
                        | staged g |> koruos/spawn:grant(c: g, handle: "console", verbs: "write", as: "fd/1", across_exec: 0)
                            | refused x |> std/io:print.ln("FAIL grant fd/1: {{ x.reason:s }}") |> koruos/spawn:abandon(x.c)
                            | ok g1 |> koruos/spawn:grant(c: g1, handle: "console", verbs: "write+admin", as: "fd/2", across_exec: 0)
                                | ok x |> std/io:print.ln("FAIL over-grant accepted") |> koruos/spawn:abandon(c: x)
                                | refused o1 |> std/io:print.ln("grant: refused reason={{ o1.reason:s }}")
                                    |> koruos/spawn:grant(o1.c, handle: "net.raw", verbs: "connect", as: "sock/0", across_exec: 0)
                                    | ok x |> std/io:print.ln("FAIL unheld handle granted") |> koruos/spawn:abandon(c: x)
                                    | refused o2 |> std/io:print.ln("grant: refused reason={{ o2.reason:s }}")
                                        |> koruos/spawn:grant(o2.c, handle: "address-space", verbs: "copy", as: "as", across_exec: 0)
                                        | ok x |> std/io:print.ln("FAIL address-space granted") |> koruos/spawn:abandon(c: x)
                                        | refused o3 |> std/io:print.ln("grant: refused reason={{ o3.reason:s }}")
                                            |> koruos/spawn:grant(o3.c, handle: "env.TERM", verbs: "read", as: "env/TERM", across_exec: 0)
                                            | refused x |> std/io:print.ln("FAIL grant env/TERM: {{ x.reason:s }}") |> koruos/spawn:abandon(x.c)
                                            | ok g2 |> koruos/spawn:grant(c: g2, handle: "console", verbs: "write", as: "fd/2", across_exec: 0)
                                                | ok x |> std/io:print.ln("FAIL bag beyond max_bag") |> koruos/spawn:abandon(c: x)
                                                | refused o4 |> std/io:print.ln("grant: refused reason={{ o4.reason:s }}")
                                                    |> koruos/spawn:seal(o4.c)
                                                    | refused x |> std/io:print.ln("FAIL seal G: {{ x.missing:s }}") |> koruos/spawn:abandon(x.c)
                                                    | sealed gs |> koruos/spawn:start(c: gs)
                                                        | stalled x |> std/io:print.ln("FAIL start G: {{ x.reason:s }}") |> koruos/spawn:abandon(x.c)
                                                        | running gr |> koruos/spawn:wait(c: gr): gw
                                                            |> std/io:print.ln("G: status={{ gw.status:d }}")
                                                            |> koruos/spawn:reap(gw.c)
                                                            // (N) the spawn authority's child limit
                                                            |> koruos/spawn:reserve(a, image: "census", budget: 4096)
                                                            | refused x |> std/io:print.ln("FAIL reserve N1: {{ x.reason:s }}")
                                                            | staged n1 |> koruos/spawn:reserve(a, image: "census", budget: 4096)
                                                                | refused x |> std/io:print.ln("FAIL reserve N2: {{ x.reason:s }}") |> koruos/spawn:abandon(c: n1)
                                                                | staged n2 |> koruos/spawn:reserve(a, image: "census", budget: 4096)
                                                                    | staged x |> std/io:print.ln("FAIL third child within max_children 2") |> koruos/spawn:abandon(c: x) |> koruos/spawn:abandon(c: n2) |> koruos/spawn:abandon(c: n1)
                                                                    | refused q3 |> std/io:print.ln("reserve3: refused reason={{ q3.reason:s }}")
                                                                        |> koruos/spawn:abandon(c: n2)
                                                                        |> koruos/spawn:abandon(c: n1)
                                                                        // (I) an image whose imports the bag does not cover
                                                                        |> koruos/spawn:reserve(a, image: "greedy", budget: 4096)
                                                                        | refused x |> std/io:print.ln("FAIL reserve greedy: {{ x.reason:s }}")
                                                                        | staged gy |> koruos/spawn:seal(c: gy)
                                                                            | sealed x |> std/io:print.ln("FAIL greedy sealed") |> koruos/spawn:abandon(c: x)
                                                                            | refused sq |> std/io:print.ln("seal: refused missing={{ sq.missing:s }}") |> koruos/spawn:abandon(sq.c)
                                                                                // (S) start only on evidence
                                                                                |> koruos/spawn:reserve(a, image: "inert", budget: 4096)
                                                                                | refused x |> std/io:print.ln("FAIL reserve inert: {{ x.reason:s }}")
                                                                                | staged in1 |> koruos/spawn:seal(c: in1)
                                                                                    | refused x |> std/io:print.ln("FAIL seal inert: {{ x.missing:s }}") |> koruos/spawn:abandon(x.c)
                                                                                    | sealed ins |> koruos/spawn:start(c: ins)
                                                                                        | running x |> std/io:print.ln("FAIL inert started") |> koruos/spawn:wait(c: x): xw |> koruos/spawn:reap(xw.c)
                                                                                        | stalled st |> std/io:print.ln("start: stalled reason={{ st.reason:s }}") |> koruos/spawn:abandon(st.c)
                                                                                            // (R) revoke
                                                                                            |> koruos/spawn:reserve(a, image: "census", budget: 4096)
                                                                                            | refused x |> std/io:print.ln("FAIL reserve R: {{ x.reason:s }}")
                                                                                            | staged rv |> koruos/spawn:grant(c: rv, handle: "console", verbs: "write", as: "fd/1", across_exec: 0)
                                                                                                | refused x |> std/io:print.ln("FAIL grant R") |> koruos/spawn:abandon(x.c)
                                                                                                | ok rv1 |> koruos/spawn:seal(c: rv1)
                                                                                                    | refused x |> std/io:print.ln("FAIL seal R") |> koruos/spawn:abandon(x.c)
                                                                                                    | sealed rvs |> koruos/spawn:revoke(c: rvs, index: 0)
                                                                                                        | refused x |> std/io:print.ln("FAIL revoke") |> koruos/spawn:abandon(x.c)
                                                                                                        | ok rvr |> koruos/spawn:start(c: rvr)
                                                                                                            | stalled x |> std/io:print.ln("FAIL start R") |> koruos/spawn:abandon(x.c)
                                                                                                            | running rr |> koruos/spawn:wait(c: rr): rw
                                                                                                                |> std/io:print.ln("R: status={{ rw.status:d }}")
                                                                                                                |> koruos/spawn:reap(rw.c)
                                                                                                                // (N) nested attenuation via authority-of
                                                                                                                |> koruos/spawn:reserve(a, image: "census", budget: 4096)
                                                                                                                | refused x |> std/io:print.ln("FAIL reserve Nest")
                                                                                                                | staged nest |> koruos/spawn:grant(c: nest, handle: "console", verbs: "write", as: "fd/1", across_exec: 0)
                                                                                                                    | refused x |> std/io:print.ln("FAIL grant Nest") |> koruos/spawn:abandon(x.c)
                                                                                                                    | ok nest1 |> koruos/spawn:seal(c: nest1)
                                                                                                                        | refused x |> std/io:print.ln("FAIL seal Nest") |> koruos/spawn:abandon(x.c)
                                                                                                                        | sealed nests |> koruos/spawn:authority-of(c: nests)
                                                                                                                            | refused x |> std/io:print.ln("FAIL authority-of") |> koruos/spawn:abandon(x.c)
                                                                                                                            | ok ao |> koruos/spawn:reserve(ao.a, image: "census", budget: 4096)
                                                                                                                                | refused x |> std/io:print.ln("FAIL reserve gc") |> koruos/spawn:abandon(ao.c)
                                                                                                                                | staged gc |> koruos/spawn:grant(c: gc, handle: "fd/1", verbs: "write+admin", as: "fd/9", across_exec: 0)
                                                                                                                                    | ok x |> std/io:print.ln("FAIL nested over-grant") |> koruos/spawn:abandon(c: x) |> koruos/spawn:abandon(ao.c)
                                                                                                                                    | refused no |> std/io:print.ln("nested: refused reason={{ no.reason:s }}")
                                                                                                                                        |> koruos/spawn:abandon(no.c)
                                                                                                                                        |> koruos/spawn:abandon(ao.c)
                                                                                                                                        |> koruos/spawn:census(): r9
                                                                                                                                        |> std/io:print.ln("roster: {{ r9:d }}")
                                                                                                                                        |> std/io:print.ln("spawn: done")
