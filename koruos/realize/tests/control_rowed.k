// CONTROL for the two negatives: same shape, only rowed lifts, no contradiction.
// `koruc ... realize gen` must exit 0 and write a Kraftfile.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
    unikraft: {{ ENTRY }}/../../../unikraft
}

import unikraft
import koruos/realize
import std/io

unikraft:image(name: "koru") {
    APPKORU_CFLAGS-y += -DKORU_RZ=1
}

std/io:print.ln("control")
