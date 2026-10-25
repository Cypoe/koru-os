// NATIVE, tick-preemption-of-kernel-continuation rung: two children on
// one roster via koruos/spawn:run2 — a busy-spinning ticker that never
// blocks, and getc.elf whose read(0) parks .conin mid-trap (kctx live).
// The monitor sendkey lands while the ticker runs at CPL3: IRQ1 only
// marks the waiter runnable — the ONLY boundary that can resume its
// kernel continuation is the next PIT tick. sched: tick_kctx=N is the
// measured proof that the tick dispatcher reached it; GOT=<c> that the
// resumed read completed itself.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/ext2
import koruos/spawn
import std/io

koruos/ext2:mount(id: 0)
| ok m |> koruos/ext2:fetch(m.fs, path: "/bin/spin.elf")
    | ok a |> koruos/ext2:fetch(a.fs, path: "getc.elf")
        | ok b |> koruos/spawn:run2(image_ptr: a.buf.ptr, image_len: a.buf.len, image2_ptr: b.buf.ptr, image2_len: b.buf.len, rights: 8070451082021771055)
            | ok e |> std/io:print.ln("tkctx: roster drained last={{ e:d }}")
                |> koruos/ext2:unmount(b.fs)
                    | ok |> std/io:print.ln("TKCTX COMPLETE")
                    | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
            | refused e |> std/io:print.ln("FAIL run2: {{ e:s }}") |> koruos/ext2:unmount(b.fs)
                | ok |> _
                | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
        | refused b |> std/io:print.ln("FAIL fetchGetc: {{ b.reason:s }}") |> koruos/ext2:unmount(b.fs)
            | ok |> _
            | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
    | refused a |> std/io:print.ln("FAIL fetchSpin: {{ a.reason:s }}") |> koruos/ext2:unmount(a.fs)
        | ok |> _
        | failed f |> std/io:print.ln("FAIL unmount: {{ f:s }}")
| refused r |> std/io:print.ln("FAIL mount: {{ r:s }}")
