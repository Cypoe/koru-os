// boot_surf — the koruos/surface lift on the native arm: two surfaces
// minted as typed *Surf<open!>, filled in their provider backing, committed
// by present(damage), pair-released by close. The empty-damage refusal is
// exercised on the wire; the visible artifact (two rects on the scanout)
// is machine-verified by QEMU screendump, not by serial self-report.
// Every arm discharges its live surfaces — the phantom state is the leak
// check, not a lint.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/surface
import std/io

koruos/surface:open(width: 320, height: 200)
| ok s |> std/io:print.ln("surf0 {{ s.width:d }}x{{ s.height:d }}")
    |> koruos/surface:fill(s.surface, x: 0, y: 0, w: 320, h: 200, color: 0x00FF00FF)
        | ok |> koruos/surface:present(s.surface, x: 0, y: 0, w: 320, h: 200)
            | ok |> koruos/surface:open(width: 160, height: 100)
                | ok t |> std/io:print.ln("surf1 {{ t.width:d }}x{{ t.height:d }}")
                    |> koruos/surface:fill(t.surface, x: 0, y: 0, w: 160, h: 100, color: 0x0000FFFF)
                        | ok |> koruos/surface:present(t.surface, x: 0, y: 0, w: 160, h: 100)
                            | ok |> koruos/surface:close(t.surface)
                                | ok |> koruos/surface:present(s.surface, x: 0, y: 0, w: 0, h: 0)
                                    | ok |> koruos/surface:close(s.surface)
                                        | ok |> std/io:print.ln("FAIL empty damage committed")
                                        | refused e1 |> std/io:print.ln("FAIL sclose: {{ e1:s }}")
                                    | refused e0 |> std/io:print.ln("empty damage refused: {{ e0:s }}")
                                        |> koruos/surface:close(s.surface)
                                            | ok |> std/io:print.ln("SURF COMPLETE")
                                            | refused e2 |> std/io:print.ln("FAIL sclose2: {{ e2:s }}")
                                | refused e3 |> koruos/surface:close(s.surface)
                                    | ok |> std/io:print.ln("FAIL tclose: {{ e3:s }}")
                                    | refused e4 |> std/io:print.ln("FAIL tclose+sclose: {{ e4:s }}")
                            | refused e5 |> koruos/surface:close(t.surface)
                                | ok |> koruos/surface:close(s.surface)
                                    | ok |> std/io:print.ln("FAIL t-present: {{ e5:s }}")
                                    | refused e6 |> std/io:print.ln("FAIL t-present+sclose: {{ e6:s }}")
                                | refused e7 |> koruos/surface:close(s.surface)
                                    | ok |> std/io:print.ln("FAIL t-present+tclose: {{ e7:s }}")
                                    | refused e8 |> std/io:print.ln("FAIL all-close: {{ e8:s }}")
                        | refused e9 |> koruos/surface:close(t.surface)
                            | ok |> koruos/surface:close(s.surface)
                                | ok |> std/io:print.ln("FAIL t-fill: {{ e9:s }}")
                                | refused ea |> std/io:print.ln("FAIL t-fill+sclose: {{ ea:s }}")
                            | refused eb |> koruos/surface:close(s.surface)
                                | ok |> std/io:print.ln("FAIL t-fill+tclose: {{ eb:s }}")
                                | refused ec |> std/io:print.ln("FAIL all-close2: {{ ec:s }}")
                | refused ed |> koruos/surface:close(s.surface)
                    | ok |> std/io:print.ln("FAIL t-open: {{ ed:s }}")
                    | refused ee |> std/io:print.ln("FAIL t-open+sclose: {{ ee:s }}")
            | refused ef |> koruos/surface:close(s.surface)
                | ok |> std/io:print.ln("FAIL s-present: {{ ef:s }}")
                | refused f0 |> std/io:print.ln("FAIL s-present+sclose: {{ f0:s }}")
        | refused f1 |> koruos/surface:close(s.surface)
            | ok |> std/io:print.ln("FAIL s-fill: {{ f1:s }}")
            | refused f2 |> std/io:print.ln("FAIL s-fill+sclose: {{ f2:s }}")
| refused f3 |> std/io:print.ln("FAIL s-open: {{ f3:s }}")
