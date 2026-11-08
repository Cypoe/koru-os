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

// One-line status for the shell 'mouse' command — full M4 diagnostic:
// aux detect/enable, IRQ12 arm, cumulative packet/desync/overflow/drop
// counters, plus cursor pos + move count.
pub fn report() void {
    const d = fb.cursorDims();
    const dg = mouse.diag();
    say("mouse: cursor ");
    koru_putdec(@intCast(@max(cx, 0)));
    say(",");
    koru_putdec(@intCast(@max(cy, 0)));
    say(" surface=");
    koru_putdec(d.w);
    say("x");
    koru_putdec(d.h);
    say(" moves=");
    koru_putdec(moves);
    say(" btns=");
    koru_putdec(pressed_n);
    say(" en=");
    say(if (enabled) "1" else "0");
    say("\nmouse: aux tried="); koru_putdec(dg.tried);
    say(" online="); koru_putdec(dg.aux_online);
    say(" irq12="); koru_putdec(dg.irq_armed);
    say(" pkts="); koru_putdec(dg.packets);
    say(" desync="); koru_putdec(dg.desyncs);
    say(" ovf="); koru_putdec(dg.overflows);
    say(" drop="); koru_putdec(dg.drops);
    say("\n");
}
