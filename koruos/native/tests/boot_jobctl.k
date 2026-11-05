// NATIVE, sessions rung: an mb2 cpio module carries /bin/jobctl; the
// initramfs view mounts it and exec spawns it under a TIGHT bag —
// read/write/close/writev + getpid + pause + fork + wait + channel
// class (bit 22: openpty/ioctl/pipe2) + proc-metadata (bit 62: kill,
// setpgid/getpgid/setsid/getsid, sigprocmask/sigaction, arch_prctl)
// + exit. The child's own JC lines are the evidence: a real session,
// a real ctty, ^Z->WUNTRACED stop report, kill(-pg,CONT) resume,
// ^C->WIFSIGNALED, and a background reader's SIGTTIN stop.
std/compiler:paths {
    koruos: {{ ENTRY }}/../..
}

import koruos/native
import koruos/initramfs
import std/io

std/io:print.ln("jobctl: begin")
|> koruos/initramfs:open(module: "jobctl.cpio")
| ok o |> koruos/initramfs:exec(o.fs, path: "/bin/jobctl", rights: 8214566287264710667)
    | ok x |> std/io:print.ln("jobctl: exec /bin/jobctl ino={{ x.ino:d }} status={{ x.status:d }}")
        |> std/io:print.ln("JOBCTL GATE COMPLETE")
    | refused xe |> std/io:print.ln("FAIL exec: {{ xe:s }}")
| refused oe |> std/io:print.ln("FAIL open: {{ oe:s }}")
