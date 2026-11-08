// koru/native/shell — minimal command shell over the fb text console.
// Line editing + dispatch; no IRQs, no runtime — ports + pixels only.
const text = @import("text.zig");
const i915drv = @import("i915/i915.zig");
const kmsdrv = @import("i915/kms.zig");
const kbd = @import("kbd");
const mouse = @import("mouse");
const cursor = @import("cursor.zig");
const hwprobe = @import("hwprobe.zig");
const xhci = @import("xhci.zig");
const net = @import("net");

var line: [96]u8 = undefined;
var n: usize = 0;
var raw: bool = false; // scan mode — dump raw 8042 bytes, ESC exits

pub fn run() noreturn {
    text.init();
    text.puts("KORU OS - native shell\n");
    text.puts("type 'help'\n\n");
    prompt();
    while (true) {
        net.heartbeat();
        if (raw) {
            if (kbd.pollRaw()) |b| {
                if (b == 0x01) { // Esc make — leave scan mode
                    raw = false;
                    text.puts("\nscan mode off\n");
                    prompt();
                } else {
                    text.puthex(b);
                    text.putc(' ');
                }
            }
        } else if (kbd.pollChar()) |c| {
            handle(c);
        }
        _ = cursor.tick(); // M4: drain mouse motion, move the cursor sprite
        // NOT hlt — IF=0 here, hlt halts the CPU on the first iteration.
        asm volatile ("pause");
    }
}
fn prompt() void {
    text.puts("> ");
}
fn handle(c: u8) void {
    if (c == '\n') {
        text.newline();
        dispatch();
        n = 0;
        prompt();
        return;
    }
    if (c == 0x08) { // backspace
        if (n > 0) {
            n -= 1;
            text.putc(0x08);
            text.putc(' ');
            text.putc(0x08);
        }
        return;
    }
    if (c >= 0x20 and c < 0x7F and n + 1 < line.len) {
        line[n] = c;
        n += 1;
        text.putc(c);
    }
}
fn dispatch() void {
    if (n == 0) return;
    if (eq("help")) {
        text.puts("commands:\n  help\n  echo <txt>\n  clear\n  about\n  scan\n  reboot\n  modeset\n  kms\n  kmsbuf\n  net\n  send <msg>\n  sendb <msg>\n  frame [msg]\n");
        return;
    }
    if (eq("net")) { cmdNet(); return; }
    if (starts("udp ")) { cmdUdp(); return; }
    if (eq("frame") or starts("frame ")) { cmdFrame(); return; }
    if (starts("send ")) { cmdSend(); return; }
    if (starts("sendb ")) { cmdSendB(); return; }
    if (eq("clear")) { text.clear(); return; }
    if (eq("i915") or eq("modeset")) { // 'modeset' = alphabetic alias (dead '5' key)
        text.puts("i915 modeset — watch last line before death\n");
        i915drv.init();
        text.puts("i915 returned — console still alive\n");
        return;
    }
    if (eq("kms")) { // M1 dumb-KMS: object model + dumb buffer + modeset
        text.puts("kms: M1 dumb-KMS — watch last line before death\n");
        kmsdrv.runModeset();
        text.puts("kms returned — console still alive\n");
        return;
    }
    if (eq("kmsbuf")) { // M1 buffer path only: alloc+map+pattern, no modeset
        text.puts("kmsbuf: dumb buffer test — panel untouched\n");
        kmsdrv.runBuffer();
        text.puts("kmsbuf returned — console still alive\n");
        return;
    }
    if (eq("kflip")) { // M2 atomic pageflip + vblank (needs live 'kms')
        text.puts("kflip: M2 atomic pageflip — watch last line\n");
        kmsdrv.runFlip();
        text.puts("kflip returned — console still alive\n");
        return;
    }
    if (eq("kdmabuf")) { // M3 dmabuf producer->scanout (needs live 'kms')
        text.puts("kdmabuf: M3 dmabuf import — watch last line\n");
        kmsdrv.runDmabuf();
        text.puts("kdmabuf returned — console still alive\n");
        return;
    }
    if (eq("mouse")) { // M4 native cursor: toggle + report position
        if (cursor.isEnabled()) {
            cursor.disable();
            text.puts("mouse: cursor off\n");
        } else {
            cursor.enable();
            text.puts("mouse: cursor on — move the TrackPoint\n");
        }
        cursor.report();
        return;
    }
    if (eq("pciscan")) { // enumerate all PCI devices + BARs
        hwprobe.pciScan();
        return;
    }
    if (eq("usb")) { // XHCI host-controller caps + port status
        hwprobe.usb();
        return;
    }
    if (eq("acpi")) { // ACPI SDT list + embedded-controller probe
        hwprobe.acpiEc();
        return;
    }
    if (eq("inputscan")) { // synthesize pointing-device bus verdict
        hwprobe.inputScan();
        return;
    }
    if (eq("smbus")) { // SMBus/I2C controller probe (0:31.4 class)
        hwprobe.smbus();
        return;
    }
    if (eq("xusb")) { // XHCI slot-enum foundation (rings + Enable Slot)
        text.puts("xusb: XHCI enumeration — watch last line\n");
        _ = xhci.init();
        text.puts("xusb returned — console still alive\n");
        return;
    }
    if (eq("reboot")) { reboot(); return; }
    if (eq("about")) {
        const d = text.dims();
        text.puts("koru-os native shell\nfb ");
        text.putdec(d.w);
        text.putc('x');
        text.putdec(d.h);
        text.puts(" console\n");
        return;
    }
    if (eq("scan")) {
        raw = true;
        text.puts("raw scancode mode - press ESC to exit\n\n");
        return;
    }
    if (starts("echo") and (n == 4 or line[4] == ' ')) {
        var i: usize = 4;
        if (i < n and line[i] == ' ') i += 1;
        while (i < n) : (i += 1) text.putc(line[i]);
        text.newline();
        return;
    }
    text.puts("unknown - try 'help'\n");
}
// whole-line exact match (single-word commands)
fn eq(s: [*:0]const u8) bool {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        if (i >= n or line[i] != s[i]) return false;
    }
    return n == i;
}
// prefix match — line begins with s (args may follow)
fn starts(s: [*:0]const u8) bool {
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        if (i >= n or line[i] != s[i]) return false;
    }
    return true;
}
fn puthex32(v: u32) void {
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        const d: u8 = @intCast((v >> @as(u5, @intCast(i * 4))) & 0xF);
        text.putc(if (d < 10) '0' + d else 'a' + d - 10);
    }
}
fn putip(ip: [4]u8) void {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (i != 0) text.putc('.');
        text.putdec(ip[i]);
    }
}
// net: NIC/link/diag/counters — the on-screen oracle when serial is dead.
fn cmdNet() void {
    const s = net.status();
    if (!s.active) {
        text.puts("net: DOWN (no NIC or init refused)\n");
        return;
    }
    text.puts("net: up  link=");
    text.puts(if (s.link) "UP " else "down ");
    text.puts("st=");
    puthex32(s.live_status);
    text.newline();
    if (s.mac) |m| {
        text.puts("  mac ");
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            if (i != 0) text.putc(':');
            text.puthex(m[i]);
        }
        text.newline();
    }
    text.puts("  ");
    putip(s.our_ip);
    text.puts(" -> ");
    putip(s.dst_ip);
    text.putc(':');
    text.putdec(s.dst_port);
    text.newline();
    const d = s.diag;
    text.puts("  init st=");
    text.putdec(d.stage);
    text.puts(" bar=");
    // bar0 is u64 — print low 32 (phys BARs here are <4GiB)
    puthex32(@truncate(d.bar0));
    text.puts(" cmd=");
    puthex32(d.cmd);
    text.puts(" tctl=");
    puthex32(d.tctl);
    text.newline();
    text.puts("  ring bal=");
    puthex32(d.td_bal);
    text.puts(" len=");
    puthex32(d.td_len);
    text.puts(" dh=");
    puthex32(d.td_h);
    text.puts(" dt=");
    puthex32(d.td_t);
    text.newline();
    text.puts("  tx sent=");
    text.putdec(s.stats.sent);
    text.puts(" done=");
    text.putdec(s.stats.completed);
    text.puts(" fail=");
    text.putdec(s.stats.failed);
    text.puts(" probe=");
    text.puts(if (s.last_probe_ok) "ok" else "none/fail");
    text.newline();
}
// skip spaces from index i; returns new index or n
fn skipSp(i: usize) usize {
    var j = i;
    while (j < n and line[j] == ' ') j += 1;
    return j;
}
fn parseIpv4(i: usize) ?struct { ip: [4]u8, next: usize } {
    var ip: [4]u8 = undefined;
    var j = i;
    var k: usize = 0;
    while (k < 4) : (k += 1) {
        if (j >= n or line[j] < '0' or line[j] > '9') return null;
        var v: u32 = 0;
        while (j < n and line[j] >= '0' and line[j] <= '9') : (j += 1) {
            v = v * 10 + (line[j] - '0');
            if (v > 255) return null;
        }
        ip[k] = @intCast(v);
        if (k != 3) {
            if (j >= n or line[j] != '.') return null;
            j += 1;
        }
    }
    return .{ .ip = ip, .next = j };
}
fn parsePort(i: usize) ?struct { port: u16, next: usize } {
    var j = skipSp(i);
    if (j >= n or line[j] < '0' or line[j] > '9') return null;
    var v: u32 = 0;
    while (j < n and line[j] >= '0' and line[j] <= '9') : (j += 1) {
        v = v * 10 + (line[j] - '0');
        if (v > 65535) return null;
    }
    return .{ .port = @intCast(v), .next = j };
}
// udp <a.b.c.d> <port> <msg> — arbitrary datagram, synchronous TX probe.
fn cmdUdp() void {
    var i: usize = skipSp(4);
    const ipr = parseIpv4(i) orelse {
        text.puts("udp: bad ip — usage: udp <a.b.c.d> <port> <msg>\n");
        return;
    };
    const pr = parsePort(ipr.next) orelse {
        text.puts("udp: bad port\n");
        return;
    };
    i = skipSp(pr.next);
    if (i >= n) {
        text.puts("udp: no message\n");
        return;
    }
    const msg = line[i..n];
    if (net.sendUdp(ipr.ip, pr.port, msg)) {
        text.puts("udp: tx descriptor COMPLETED (dd) — frame left the MAC\n");
    } else {
        text.puts("udp: TX failed/timeout — see 'net' for counters\n");
    }
    text.newline();
}
// frame [msg] — payload-only: fixed P2P path, no args needed. Bare
// 'frame' dumps a canned probe. Hex-dumps the exact TX frame (no send):
// dst MAC must read ff:ff:ff:ff:ff:ff, bytes 12-13 = 08 00, IP proto at
// frame[23] = 11, UDP dport at frame[36..38].
fn cmdFrame() void {
    var msg: []const u8 = "probe";
    const i = skipSp(5); // past "frame"
    if (i < n) msg = line[i..n];
    const f = net.peekMsg(msg) orelse {
        text.puts("frame: build refused\n");
        return;
    };
    text.puts("frame len=");
    text.putdec(f.len);
    const cs = net.lastChecksums();
    text.puts("  ipcsum=");
    puthex32(cs.ip);
    text.puts(" udpcsum=");
    puthex32(cs.udp);
    text.newline();
    var off: usize = 0;
    while (off < f.len and off < 96) : (off += 1) {
        if (off % 16 == 0) {
            text.puthex(@intCast(off));
            text.putc(' ');
        }
        text.puthex(f[off]);
        text.putc(' ');
        if (off % 16 == 15) text.newline();
    }
    if (f.len % 16 != 0 and f.len < 96) text.newline();
}
// send <msg> — payload-only: fixed P2P path (192.168.99.2 -> .99.1:47820,
// broadcast MAC, ethertype hardcoded). Short command for the flaky
// keyboard; 'udp <ip> <port> <msg>' remains for arbitrary targets.
fn cmdSend() void {
    const i = skipSp(5);
    if (i >= n) {
        text.puts("send: no message\n");
        return;
    }
    if (net.sendMsg(line[i..n])) {
        text.puts("send: tx descriptor COMPLETED (dd)\n");
    } else {
        text.puts("send: TX failed/timeout — see 'net'\n");
    }
    text.newline();
}
// sendb <msg> — broadcast MAC + broadcast IP (192.168.99.255): the
// standard broadcast frame, A/B against 'send' (unicast MAC+IP).
fn cmdSendB() void {
    const i = skipSp(6);
    if (i >= n) {
        text.puts("sendb: no message\n");
        return;
    }
    if (net.sendBcast(line[i..n])) {
        text.puts("sendb: tx descriptor COMPLETED (dd)\n");
    } else {
        text.puts("sendb: TX failed/timeout — see 'net'\n");
    }
    text.newline();
}
fn reboot() noreturn {
    // pulse the 8042 reset line — bit 0 of the output port
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (@as(u8, 0xFE)),
          [port] "N{dx}" (@as(u16, 0x64)),
        : .{ .memory = true });
    while (true) asm volatile ("hlt");
}
