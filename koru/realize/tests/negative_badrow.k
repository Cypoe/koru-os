// NEGATIVE (declaration phase): a lift whose `koruos/realize:row` is malformed
// (binds[0] lacks "arm"). `koruc ... realize gen` must write a refused: line
// naming the module and the missing field, and the interface it meant to serve
// stays unrowed.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
    rzfix: {{ ENTRY }}
    unikraft: {{ ENTRY }}/../../../unikraft
}

import unikraft
import koruos/realize
import rzfix/badrow
import std/io

unikraft:image(name: "koru") {
    APPKORU_CFLAGS-y += -DKORU_RZ=1
}

rzfix/badrow:ping(): n |> std/io:print.ln("n={{ n:d }}")
