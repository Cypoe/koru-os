// koru/native cursor — M4 native mouse cursor.
//
// The PS/2 aux driver (mouse.zig) already decodes TrackPoint packets into
// a ring of motion/button events. This module is the consumer: each tick
// drains motion deltas, integrates them into a cursor position clamped to
// the live fb surface, and moves an XOR-blended arrow sprite.
//
// XOR drawing is the classic hardware-cursor trick: drawing and erasing
// are the same operation (XOR is self-inverse), so no under-pixel
// snapshot is needed and the sprite composites over console text, the
// M1 pattern, or a dmabuf flip without bookkeeping. Single XOR colour —
// visible on dark and light content alike.
//
// Input routing: motion events update cx/cy; position is mirrored to UDP
// (net.mark) so the host sees live cursor coords — the "desktop is alive"
// oracle. A 'mouse' shell command toggles + reports.

const mouse = @import("mouse");
const fb = @import("fb.zig");
const net = @import("net");
const text = @import("text.zig");
const acpi = @import("acpi");
const ioapic = @import("ioapic");
const user = @import("user");
const pmm = @import("pmm");

extern var stdout: ?*anyopaque;
extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern fn koru_putdec(v: u64) void;

const SPR_W: u32 = 12;
const SPR_H: u32 = 12;
const XOR: u32 = 0x00FFFFFF; // white XOR — inverts whatever is beneath

var cx: i32 = 0;
var cy: i32 = 0;
var init_d: bool = false;
var shown: bool = false;
var enabled: bool = false;
var moves: u64 = 0;
var pressed_n: u32 = 0;
var input_armed: bool = false;
var pkt_marked: bool = false;

// ensureInput — the shell path boots with fullBoot=false, so the doFull
// init block (acpi/pci/ioapic/user/kbd/mouse/smp) never ran and
// mouse.init() was dead code: every M4 "aux=0" measured an un-run
// driver. IRQ delivery needs user.init (IDT+PIC+sti); IRQ12 then routes
// via ioapic when MADT exists, else the PIC fallback lands it on vec
// 0x2C which irq_exc_dispatch already claims. kbd.init is deliberately
// skipped — IRQ1 would steal scancodes from the shell's pollChar path.
fn ensureInput() void {
    if (input_armed) return;
    input_armed = true;
    // Stage markers bracket every bring-up step — a hang on real HW now
    // names the stage on the wire instead of silence after 'mouse'.
    net.mark("in:begin");
    net.mark("in:acpi");
    acpi.init(pmm.boot_mbi); // MADT -> ioapic routes (no-op if absent)
    net.mark("in:acpi-done");
    net.mark("in:ioapic");
    ioapic.init();
    net.mark("in:ioapic-done");
    net.mark("in:user");
    user.init();  // IDT + PIC remap + LAPIC + sti — interrupts live
    net.mark("in:user-done");
    net.mark("in:mouse");
    mouse.init(); // 8042 aux + TrackPoint sequence + IRQ12 unmask
    net.mark("in:mouse-done");
}

// 12x12 arrow sprite, tip at top-left. '1' = on-pixel (XOR'd).
const SPRITE = [SPR_H]u16{
    0b100000000000,
    0b110000000000,
    0b101000000000,
    0b100100000000,
    0b100010000000,
    0b100011000000,
    0b100001100000,
    0b100000110000,
    0b100000011000,
    0b100000001100,
    0b111111111100,
    0b011111111000,
};

fn say(s: [*:0]const u8) void {
    _ = fputs(s, stdout);
}

fn drawSprite(x: i32, y: i32) void {
    var sy: u32 = 0;
    while (sy < SPR_H) : (sy += 1) {
        var sx: u32 = 0;
        while (sx < SPR_W) : (sx += 1) {
            if ((SPRITE[sy] >> @intCast(SPR_W - 1 - sx)) & 1 == 0) continue;
            const px = x + @as(i32, @intCast(sx));
            const py = y + @as(i32, @intCast(sy));
            if (px < 0 or py < 0) continue;
            const ux: u32 = @intCast(px);
            const uy: u32 = @intCast(py);
            fb.putPx(ux, uy, fb.getPx(ux, uy) ^ XOR);
        }
    }
}

fn hideSprite() void {
    if (!shown) return;
    drawSprite(cx, cy); // XOR again = erase
    shown = false;
}

// Centre the cursor on the current surface and arm it.
// M4 diagnostic: sprite is FORCED to a fixed corner (50,50) so a static
// arrow on-panel proves the draw path reaches the visible surface even if
// no mouse packets ever stream. Motion still moves it if packets arrive.
pub fn enable() void {
    const d = fb.cursorDims();
    if (!d.live) return;
    ensureInput(); // lazy interrupt+aux bring-up (shell path skips doFull)
    cx = 50;
    cy = 50;
    enabled = true;
    init_d = true;
    // UDP markers split the two failure modes:
    //   aux=1/0      -> PS/2 aux device detected+enabled at boot
    //   irq=1/0      -> IRQ12 unmasked
    //   pkts=live/0  -> cumulative packets received so far
    //   sprite@50,50 -> draw path executed on the live fb surface
    const dg = mouse.diag();
    // 8042 handshake-step markers (results recorded at boot init):
    if (dg.selftest == 0x55) net.mark("cursor:8042=selftest-ok")
    else net.mark("cursor:8042=selftest-bad");
    if (dg.auxen != 0) net.mark("cursor:auxen=1") else net.mark("cursor:auxen=0");
    if (dg.pollbytes != 0) net.mark("cursor:poll=live") else net.mark("cursor:poll=0");
    if (dg.aux_online != 0) net.mark("cursor:aux=1") else net.mark("cursor:aux=0");
    if (dg.irq_armed != 0) net.mark("cursor:irq=1") else net.mark("cursor:irq=0");
    if (dg.packets != 0) net.mark("cursor:pkts=live") else net.mark("cursor:pkts=0");
    hideSprite();
    drawSprite(cx, cy);
    shown = true;
    net.mark("cursor:sprite@50,50");
    net.mark("cursor: enabled");
}

pub fn disable() void {
    hideSprite();
    enabled = false;
    net.mark("cursor: disabled");
}

pub fn isEnabled() bool {
    return enabled;
}

// Drain pending mouse events, integrate motion, move the sprite.
// Call once per shell-loop iteration. Returns true if the cursor moved.
pub fn tick() bool {
    if (!enabled or !init_d) return false;
    var moved = false;
    while (mouse.pop()) |ev| {
        if (ev.kind == 3) { // motion — raw device deltas, y already surface-space
            cx += ev.dx;
            cy += ev.dy;
            moves += 1;
            moved = true;
        } else if (ev.kind == 2) { // button edge — count held buttons
            if (ev.pressed != 0) pressed_n += 1 else if (pressed_n > 0) pressed_n -= 1;
        }
    }
    // first decoded packet -> one UDP marker proving the stream is live
    // (kept out of the IRQ path — net TX is not reentrant-safe there)
    if (!pkt_marked and mouse.diag().packets != 0) {
        pkt_marked = true;
        net.mark("mouse:streaming");
    }
    if (!moved) return false;
    const d = fb.cursorDims();
    if (!d.live) return false;
    const maxX = @as(i32, @intCast(d.w)) - @as(i32, SPR_W);
    const maxY = @as(i32, @intCast(d.h)) - @as(i32, SPR_H);
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    if (cx > maxX) cx = maxX;
    if (cy > maxY) cy = maxY;
    hideSprite();
    drawSprite(cx, cy);
    shown = true;
    // UDP mirror on a stride + always the first motion so the oracle sees
    // the cursor alive immediately without flooding the listener.
    if (moves == 1 or moves % 16 == 0) net.mark("cursor: move");
    return true;
}

// One-line status for the shell 'mouse' command — full diagnostic:
// aux detect/enable, IRQ12 arm, TrackPoint variant/fw/POR, packet/
// desync/overflow/drop counters, plus cursor pos + move count.
// Console path = text.* (panel + UDP mirror — the T590 oracle);
// serial gets one compact line for QEMU logs.
pub fn report() void {
    const d = fb.cursorDims();
    const dg = mouse.diag();
    text.puts("mouse: cursor ");
    text.putdec(@intCast(@max(cx, 0)));
    text.putc(',');
    text.putdec(@intCast(@max(cy, 0)));
    text.puts(" surface=");
    text.putdec(d.w);
    text.putc('x');
    text.putdec(d.h);
    text.puts(" moves=");
    text.putdec(moves);
    text.puts(" btns=");
    text.putdec(pressed_n);
    text.puts(" en=");
    text.puts(if (enabled) "1" else "0");
    text.newline();
    text.puts("mouse: aux tried="); text.putdec(dg.tried);
    text.puts(" online="); text.putdec(dg.aux_online);
    text.puts(" irq12="); text.putdec(dg.irq_armed);
    text.puts(" pkts="); text.putdec(dg.packets);
    text.puts(" desync="); text.putdec(dg.desyncs);
    text.puts(" ovf="); text.putdec(dg.overflows);
    text.puts(" drop="); text.putdec(dg.drops);
    text.newline();
    text.puts("mouse: 8042 selftest="); text.putdec(dg.selftest);
    text.puts(" ccb="); text.putdec(dg.ccb);
    text.puts(" auxen="); text.putdec(dg.auxen);
    text.puts(" pollbytes="); text.putdec(dg.pollbytes);
    text.puts(" f6="); text.putdec(dg.f6);
    text.newline();
    text.puts("mouse: tp variant="); text.putdec(dg.variant);
    text.puts(" fw="); text.puthex(@intCast(dg.firmware));
    text.puts(" por="); text.putdec(dg.por);
    text.puts(" cfg="); text.putdec(dg.cfg);
    text.newline();
    // serial compact — QEMU -serial oracle
    say("mouse: aux online="); koru_putdec(dg.aux_online);
    say(" irq12="); koru_putdec(dg.irq_armed);
    say(" pkts="); koru_putdec(dg.packets);
    say(" tpv="); koru_putdec(dg.variant);
    say(" por="); koru_putdec(dg.por);
    say("\n");
}
