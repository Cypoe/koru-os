// koru/native/shell — minimal command shell over the fb text console.
// Line editing + dispatch; no IRQs, no runtime — ports + pixels only.
const text = @import("text.zig");
const i915drv = @import("i915/i915.zig");
const kbd = @import("kbd");

var line: [96]u8 = undefined;
var n: usize = 0;
var raw: bool = false; // scan mode — dump raw 8042 bytes, ESC exits

pub fn run() noreturn {
    text.init();
    text.puts("KORU OS - native shell\n");
    text.puts("type 'help'\n\n");
    prompt();
    while (true) {
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
        text.puts("commands:\n  help\n  echo <txt>\n  clear\n  about\n  scan\n  reboot\n  i915\n");
        return;
    }
    if (eq("clear")) { text.clear(); return; }
    if (eq("i915")) {
        text.puts("i915 modeset — watch last line before death\n");
        i915drv.init();
        text.puts("i915 returned — console still alive\n");
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
fn reboot() noreturn {
    // pulse the 8042 reset line — bit 0 of the output port
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (@as(u8, 0xFE)),
          [port] "N{dx}" (@as(u16, 0x64)),
        : .{ .memory = true });
    while (true) asm volatile ("hlt");
}
