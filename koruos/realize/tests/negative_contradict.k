// NEGATIVE (configure phase): uses no scheduler, so realize derives
// CONFIG_LIBUKSCHEDCOOP=n; the author line below asks for 'y'. realize must exit 3
// with a "contradicts derived" refusal and write no Kraftfile.
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

unikraft:kconfig {
    CONFIG_LIBUKSCHEDCOOP: 'y'
}

std/io:print.ln("never built")
