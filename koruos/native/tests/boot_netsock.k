// NATIVE, net-uart-relay rung: an mb2 cpio module carries /bin/nettest
// — a static C oracle that runs the AF_INET surface end-to-end through
// the COM2 host bridge (a second -serial riding TCP to netrelay.py on
// the host, the real TCP stack placement — delegation, like slirp under
// a NIC, named honestly). The bag reuses the shpty grant set: the
// channel class (22) already folds socket/connect/send/recv/poll/
// shutdown/getsockopt; the child's NET lines are the evidence —
// connect(10.0.2.2:1234), HTTP/1.1 200 from whatever owns the host port
// (llmstub.py answers when it's free; live LM Studio serves the same
// shapes when it isn't), ECONNREFUSED on a dead port, clean EOS on
// Connection: close.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/initramfs
import std/io

std/io:print.ln("netsock: begin")
|> koruos/initramfs:open(module: "netsock.cpio")
| ok o |> koruos/initramfs:exec(o.fs, path: "/bin/nettest", rights: 8214566321624457007)
    | ok x |> std/io:print.ln("netsock: exec /bin/nettest ino={{ x.ino:d }} status={{ x.status:d }}")
        |> std/io:print.ln("NETSOCK GATE COMPLETE")
    | refused xe |> std/io:print.ln("FAIL exec: {{ xe:s }}")
| refused oe |> std/io:print.ln("FAIL open: {{ oe:s }}")
