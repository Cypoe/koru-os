// POSITIVE, the NID binding layer (DESIGN-0001 §11.5 item 3) in a Koru-built Unikraft image.
// Checked by ../../../experiments/nid/check.py. Layout at build time
// (experiments/nid/build-nid.sh): <root>/koruos/nid/tests/boot_nid.k and <root>/unikraft
// (koru-libs @ ff5cb559). Built through koruos/realize (no hand kconfig for the allocator,
// stack or scheduler).
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

unikraft:kconfig {
    CONFIG_OPTIMIZE_SIZE: 'y'
    CONFIG_OPTIMIZE_DEADELIM: 'y'
    CONFIG_LIBUKBOOT_BANNER_NONE: 'y'
    CONFIG_LIBUKDEBUG_ENABLE_ASSERT: 'n'
}

std/io:print.ln("nid: begin")
// (1) refusals at open: each manifest is wrong in exactly one way
|> koruos/nid:open(manifest: "create c/libc/1/fputs -> koruos.console.write@1 => console_com1_v1:write; create c/libc/1/fputs -> koruos.clock.monotonic@1 => clock_uk_v1:now", nid_bits: 64)
| ok t |> std/io:print.ln("FAIL open1 accepted an overwrite") |> koruos/nid:close(t)
| refused o1 |> std/io:print.ln("open1: refused reason={{ o1.reason:s }}")
    |> koruos/nid:open(manifest: "create c/libc/1/fputs -> koruos.console.write@2 => console_com1_v1:write", nid_bits: 64)
    | ok t |> std/io:print.ln("FAIL open2 accepted a descriptor mismatch") |> koruos/nid:close(t)
    | refused o2 |> std/io:print.ln("open2: refused reason={{ o2.reason:s }} other={{ o2.other:s }}")
        |> koruos/nid:open(manifest: "create c/libc/1/fputs -> koruos.console.write@1 => console_virtio_v1:write", nid_bits: 64)
        | ok t |> std/io:print.ln("FAIL open3 accepted an unlinked export") |> koruos/nid:close(t)
        | refused o3 |> std/io:print.ln("open3: refused reason={{ o3.reason:s }} other={{ o3.other:s }}")
            |> koruos/nid:open(manifest: "evolve c/libc/1/fputs -> koruos.console.write@2 => console_com1_v2:write", nid_bits: 64)
            | ok t |> std/io:print.ln("FAIL open4 accepted an orphan evolve") |> koruos/nid:close(t)
            | refused o4 |> std/io:print.ln("open4: refused reason={{ o4.reason:s }}")
            // (2) a deliberately narrow NID (4 bits): 17 distinct foreign names cannot all be unique
                |> koruos/nid:open(manifest: "create c/t/1/f00 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f01 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f02 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f03 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f04 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f05 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f06 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f07 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f08 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f09 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f10 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f11 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f12 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f13 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f14 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f15 -> koruos.clock.monotonic@1 => clock_uk_v1:now; create c/t/1/f16 -> koruos.clock.monotonic@1 => clock_uk_v1:now", nid_bits: 4)
                | ok t |> std/io:print.ln("FAIL open5 accepted 17 names in 4 bits") |> koruos/nid:close(t)
                | refused o5 |> std/io:print.ln("open5: refused reason={{ o5.reason:s }} at={{ o5.at:s }} other={{ o5.other:s }}")
                // (3) the binding chain: two foreign names asserted onto one canonical interface
                    |> koruos/nid:open(manifest: "create c/libc/1/fputs -> koruos.console.write@1 => console_com1_v1:write; create linux/x86_64/1/write -> koruos.console.write@1 => console_com1_v1:write; create c/libc/1/clock_gettime -> koruos.clock.monotonic@1 => clock_uk_v1:now", nid_bits: 64)
                    | refused o6 |> std/io:print.ln("FAIL open6: {{ o6.reason:s }} at={{ o6.at:s }}")
                    | ok t6 |> koruos/nid:resolve(t: t6, foreign: "c/libc/1/fputs")
                        | refused x |> std/io:print.ln("FAIL resolve fputs") |> koruos/nid:close(x.t)
                        | bound a |> koruos/nid:call(a.b, arg: "hello via c/libc/1/fputs")
                            | stale s |> std/io:print.ln("FAIL call a stale") |> koruos/nid:release(s.b) |> koruos/nid:close(a.t)
                            | ok ca |> std/io:print.ln("call: n={{ ca.n:d }}")
                                |> koruos/nid:resolve(a.t, foreign: "linux/x86_64/1/write")
                                | refused x |> std/io:print.ln("FAIL resolve write") |> koruos/nid:release(ca.b) |> koruos/nid:close(x.t)
                                | bound w |> koruos/nid:call(w.b, arg: "hello via linux/x86_64/1/write")
                                    | stale s |> std/io:print.ln("FAIL call w stale") |> koruos/nid:release(s.b) |> koruos/nid:release(ca.b) |> koruos/nid:close(w.t)
                                    | ok cw |> std/io:print.ln("call: n={{ cw.n:d }}")
                                        // (4) unbound NIDs: unknown name, and a known name at another version
                                        |> koruos/nid:probe(w.t, foreign: "c/libc/1/puts")
                                        | bound x |> std/io:print.ln("FAIL bound puts") |> koruos/nid:release(x.b) |> koruos/nid:release(cw.b) |> koruos/nid:release(ca.b) |> koruos/nid:close(x.t)
                                        | refused un1 |> std/io:print.ln("unbound: foreign={{ un1.foreign:s }} nid={{ un1.nid:s }} phase={{ un1.phase:s }} missing={{ un1.missing:s }} offered=[{{ un1.offered:s }}]")
                                            |> koruos/nid:probe(un1.t, foreign: "c/libc/2/fputs")
                                            | bound x |> std/io:print.ln("FAIL bound fputs@2") |> koruos/nid:release(x.b) |> koruos/nid:release(cw.b) |> koruos/nid:release(ca.b) |> koruos/nid:close(x.t)
                                            | refused un2 |> std/io:print.ln("unbound: foreign={{ un2.foreign:s }} nid={{ un2.nid:s }} phase={{ un2.phase:s }} missing={{ un2.missing:s }} offered=[{{ un2.offered:s }}]")
                                                // (5) the clock through its foreign name
                                                |> koruos/nid:resolve(un2.t, foreign: "c/libc/1/clock_gettime")
                                                | refused x |> std/io:print.ln("FAIL resolve clock") |> koruos/nid:release(cw.b) |> koruos/nid:release(ca.b) |> koruos/nid:close(x.t)
                                                | bound k |> koruos/nid:call(k.b, arg: "")
                                                    | stale s |> std/io:print.ln("FAIL clock stale") |> koruos/nid:release(s.b) |> koruos/nid:release(cw.b) |> koruos/nid:release(ca.b) |> koruos/nid:close(k.t)
                                                    | ok ck |> std/io:print.ln("clock: ns={{ ck.n:d }}") |> koruos/nid:release(ck.b)
                                                        // (6) retarget the interface: same NIDs, new provider
                                                        |> koruos/nid:retarget(k.t, iface: "koruos.console.write@2", to: "console_tag_v1:write")
                                                        | ok x |> std/io:print.ln("FAIL retarget across revisions accepted") |> koruos/nid:release(cw.b) |> koruos/nid:release(ca.b) |> koruos/nid:close(x.t)
                                                        | refused rr |> std/io:print.ln("retarget: refused reason={{ rr.reason:s }}")
                                                            |> koruos/nid:retarget(rr.t, iface: "koruos.console.write@1", to: "console_tag_v1:write")
                                                            | refused x |> std/io:print.ln("FAIL retarget: {{ x.reason:s }}") |> koruos/nid:release(cw.b) |> koruos/nid:release(ca.b) |> koruos/nid:close(x.t)
                                                            | ok g |> std/io:print.ln("retarget: rows={{ g.rows:d }} gen={{ g.generation:d }}")
                                                                |> koruos/nid:call(ca.b, arg: "old binding after retarget")
                                                                | ok x |> std/io:print.ln("FAIL stale binding was redirected") |> koruos/nid:release(x.b) |> koruos/nid:release(cw.b) |> koruos/nid:close(g.t)
                                                                | stale st |> std/io:print.ln("stale: held={{ st.held:d }} now={{ st.now:d }}") |> koruos/nid:release(st.b)
                                                                    |> koruos/nid:release(cw.b)
                                                                    |> koruos/nid:resolve(g.t, foreign: "c/libc/1/fputs")
                                                                    | refused x |> std/io:print.ln("FAIL re-resolve") |> koruos/nid:close(x.t)
                                                                    | bound a2 |> koruos/nid:call(a2.b, arg: "re-resolved after retarget")
                                                                        | stale s |> std/io:print.ln("FAIL re-resolved stale") |> koruos/nid:release(s.b) |> koruos/nid:close(a2.t)
                                                                        | ok c2 |> koruos/nid:release(c2.b) |> koruos/nid:close(a2.t)
                    

// (7) evolve, don't mutate: a new revision occludes the old row, which stays (second top-level flow)
std/io:print.ln("nid: evolve")
|> koruos/nid:open(manifest: "create c/libc/1/fputs -> koruos.console.write@1 => console_com1_v1:write; evolve c/libc/1/fputs -> koruos.console.write@2 => console_com1_v2:write", nid_bits: 64)
| refused o7 |> std/io:print.ln("FAIL open7: {{ o7.reason:s }} at={{ o7.at:s }}")
| ok t7 |> koruos/nid:resolve(t: t7, foreign: "c/libc/1/fputs")
    | refused x |> std/io:print.ln("FAIL resolve evolved") |> koruos/nid:close(x.t)
    | bound e |> koruos/nid:call(e.b, arg: "hello via the evolved row")
        | stale s |> std/io:print.ln("FAIL evolved stale") |> koruos/nid:release(s.b) |> koruos/nid:close(e.t)
        | ok ce |> koruos/nid:release(ce.b) |> koruos/nid:close(e.t) |> std/io:print.ln("nid: done")
