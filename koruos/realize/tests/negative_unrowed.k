// NEGATIVE (configure phase): uses a lift with no realize row. `koruc ... realize gen`
// must exit 3, write no Kraftfile and name the interface in a refused: line.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
    rzfix: {{ ENTRY }}
    unikraft: {{ ENTRY }}/../../../unikraft
}

import unikraft
import koruos/realize
import rzfix/unrowed
import std/io

unikraft:image(name: "koru") {
    APPKORU_CFLAGS-y += -DKORU_RZ=1
}

rzfix/unrowed:census(): n |> std/io:print.ln("n={{ n:d }}")
