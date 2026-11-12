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
const user = @import("user");
const std = @import("std");

extern var stdout: ?*anyopaque;
extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern fn koru_putdec(v: u64) void;

const SPR_W: u32 = 12;
const SPR_H: u32 = 12;
pub const SPR_W_PUB = SPR_W;
pub const SPR_H_PUB = SPR_H;
const XOR: u32 = 0x00FFFFFF; // white XOR — inverts whatever is beneath

var cx: i32 = 0;
var cy: i32 = 0;
var ox: i32 = 0; // last DRAWN pos — hide must erase here, not at cx,cy
var oy: i32 = 0;
var tick_n: u64 = 0;
var init_d: bool = false;
var shown: bool = false;
var enabled: bool = false;
var moves: u64 = 0;
var pressed_n: u32 = 0;
var input_armed: bool = false;
var pkt_marked: bool = false;
var drawn_gen: u64 = 0; // fb.generation() the sprite was last drawn on
var diag_n: u64 = 0;   // cumulative motion events seen (wire stride)
var edge_n: u64 = 0;   // clamp/edge markers emitted
// motionDiag gates the per-motion sayU/net.mark diagnostics — they
// dual-write serial (~87us/byte) AND UDP (submit can block TX_MAX_NS
// on a stuck ring) every 16th motion event. During a drag that's
// constant blocking I/O inside cursor.tick (measured 'hot cur').
// Bring-up debug leftovers; off by default, flip for cursor hunts.
pub var motionDiag: bool = false;

// ensureInput — the shell path boots with fullBoot=false, so the doFull
// init block (acpi/pci/ioapic/user/kbd/mouse/smp) never ran and
// mouse.init() was dead code: every M4 "aux=0" measured an un-run
// driver. IRQ delivery needs only user.init (IDT + PIC remap + sti).
// acpi.init/ioapic.init are deliberately NOT run here: acpi.init hung
// twice on the T590's real tables (mb2 walk, then deeper SDT/MADT) and
// input doesn't need it — IRQ12 reaches vec 0x2C through the PIC
// fallback in koru_irq_unmask (slave bit + cascade unmask), and
// ioapic.gsiFor/isLapic early-return on !live so eoiVec takes picEoi.
// kbd.init is skipped — IRQ1 would steal scancodes from pollChar.
fn ensureInput() void {
    if (input_armed) return;
    input_armed = true;
    // Stage markers bracket every bring-up step — a hang on real HW now
    // names the stage on the wire instead of silence after 'mouse'.
    net.mark("in:begin");
    net.mark("in:acpi-skip"); // acpi/ioapic bypassed — PIC door for IRQ12
    net.mark("in:user");
    user.init();  // IDT + PIC remap + LAPIC + sti — interrupts live
    net.mark("in:user-done");
    net.mark("in:mouse");
    mouse.init(); // 8042 aux + TrackPoint sequence + IRQ12 unmask
    net.mark("in:mouse-done");
}

// 12x12 FILLED arrow, tip at top-left (the hotspot). Solid silhouette —
// ~3x the on-pixels of the old 1px outline, unmistakable against console
// text and the console's dark-blue background. Still XOR'd: draw and
// erase are the same op, so it composites over any surface content.
const SPRITE = [SPR_H]u16{
    0b100000000000,
    0b110000000000,
    0b111000000000,
    0b111100000000,
    0b111110000000,
    0b111111000000,
    0b111111100000,
    0b111111110000,
    0b111111111000,
    0b111111111111, // head bottom + tail top — bar extends right
    0b111111111111,
    0b011111111110, // tail bottom, slight taper
};

// ---- scene backing -------------------------------------------------------
// The cursor is a comp layer now — an opaque arrow with a CURSOR_CLEAR
// surround, not an XOR overlay. Expand the 1bpp SPRITE once into a static
// u32 backing: set bits -> white fill, unset 8-neighbours of set bits ->
// dark outline, everything else -> transparent. .bss sits inside the
// identity map (VA==PA) so gpublt's mapBacking GGTT-maps it like any
// other layer backing — no pmm needed for 576 bytes.
pub const CURSOR_W: u32 = 12;
pub const CURSOR_H: u32 = 12;
const FILL: u32 = 0xFFFF_FFFF;
const OUTLINE: u32 = 0xFF11_1111;
// px == 0 is comp.CURSOR_CLEAR — the transparent sentinel both backends
// honour (pxIn falls through, gpublt skips the run).

var cursor_px: [144]u32 = undefined;
var cursor_ready: bool = false;

pub fn backingInit() void {
    if (cursor_ready) return;
    for (0..144) |i| {
        const dx: usize = i % 12;
        const dy: usize = i / 12;
        const set = ((SPRITE[dy] >> @intCast(11 - dx)) & 1) != 0;
        if (set) {
            cursor_px[i] = FILL;
            continue;
        }
        var edge = false;
        var ey: i32 = -1;
        while (ey <= 1 and !edge) : (ey += 1) {
            var ex: i32 = -1;
            while (ex <= 1 and !edge) : (ex += 1) {
                if (ex == 0 and ey == 0) continue;
                const nx = @as(i32, @intCast(dx)) + ex;
                const ny = @as(i32, @intCast(dy)) + ey;
                if (nx < 0 or ny < 0 or nx >= 12 or ny >= 12) continue;
                const nset = ((SPRITE[@intCast(ny)] >>
                    @intCast(11 - @as(usize, @intCast(nx)))) & 1) != 0;
                if (nset) edge = true;
            }
        }
        cursor_px[i] = if (edge) OUTLINE else 0;
    }
    cursor_ready = true;
}

pub fn backing() ?[*]u32 {
    if (!cursor_ready) return null;
    return @ptrCast(&cursor_px);
}

fn say(s: [*:0]const u8) void {
    _ = fputs(s, stdout);
}

// sayU — dual-write one formatted line: serial AND the UDP mirror, same
// discipline as mouse.zig (the T590 oracle lives on the wire).
fn sayU(comptime fmt: []const u8, args: anytype) void {
    var buf: [192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    buf[s.len] = 0;
    _ = fputs(@ptrCast(&buf), stdout);
    net.mirror(s);
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
    drawSprite(ox, oy); // XOR again = erase — at the DRAWN pos
    shown = false;
}

// Centre the cursor on the current surface and arm it.
// The sprite is composited by tick() every redraw — enable just parks
// the logical position at screen centre and lets the first tick paint.
pub fn enable() void {
    const d = fb.cursorDims();
    if (!d.live) return;
    ensureInput(); // lazy interrupt+aux bring-up (shell path skips doFull)
    cx = @as(i32, @intCast(d.w / 2)) - @as(i32, @intCast(SPR_W / 2));
    cy = @as(i32, @intCast(d.h / 2)) - @as(i32, @intCast(SPR_H / 2));
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
    if (!sceneOwned) {
        hideSprite();
        drawSprite(cx, cy);
        ox = cx;
        oy = cy;
        shown = true;
        drawn_gen = fb.generation();
        net.mark("cursor:sprite");
    }
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

// pointer state for the window/compositor layer — position is the
// sprite tip (the arrow's hotspot is its top-left pixel), held is the
// count of currently-down buttons.
pub const Pos = struct { x: i32, y: i32 };
pub fn pos() Pos {
    return .{ .x = cx, .y = cy };
}
pub fn buttonsHeld() u32 {
    // authoritative packet bitmask, not the drift-prone pressed_n count —
    // a desynced count latches held=true and kills every later click.
    return @intCast(@popCount(mouse.buttons()));
}

// ---- scene-compositor mode (MC-1) -----------------------------------------
// When the scene core owns the display, cursor.zig keeps ONLY the device
// side: packet drain, position, buttons, markers. The sprite is painted
// by comp's composite (damage-tracked), so every direct fb draw/erase
// below becomes a no-op — no XOR writes outside the damage pass.
var sceneOwned: bool = false;
pub fn setSceneOwned(b: bool) void {
    sceneOwned = b;
    if (b) { shown = false; } // forget any direct-drawn sprite state
}

// sprite() — the rect + visibility the scene needs for hit-independent
// damage and overlay. on = enabled and positioned (init_d done).
pub const Sprite = struct { x: i32, y: i32, w: i32, h: i32, on: bool };
pub fn sprite() Sprite {
    return .{
        .x = cx, .y = cy,
        .w = @intCast(SPR_W), .h = @intCast(SPR_H),
        .on = enabled and init_d,
    };
}
// composite suspend/resume — a non-XOR writer (the window blit) is
// about to repaint a rect that may contain the sprite. Erase now so
// the blit sees pure scene pixels; redraw on top afterwards. Both are
// safe no-ops when the cursor isn't enabled.
pub fn compositeSuspend() void {
    if (sceneOwned) return;
    hideSprite();
}
pub fn compositeResume() void {
    if (sceneOwned) return;
    if (!enabled or shown) return;
    drawSprite(cx, cy);
    ox = cx;
    oy = cy;
    shown = true;
    drawn_gen = fb.generation();
}

// Drain pending mouse events, integrate motion, move the sprite.
// Call once per shell-loop iteration. Returns true if the cursor moved.
pub fn tick() bool {
    if (!enabled or !init_d) return false;
    var moved = false;
    var last_dx: i32 = 0;
    var last_dy: i32 = 0;
    var evs: u64 = 0;
    while (mouse.pop()) |ev| {
        if (ev.kind == 3) { // motion — raw device deltas, y already surface-space
            cx += ev.dx;
            cy += ev.dy;
            last_dx = ev.dx;
            last_dy = ev.dy;
            evs += 1;
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
    const d = fb.cursorDims();
    if (!d.live) return false;
    const g = fb.generation();
    const stale = g != drawn_gen;
    drawn_gen = g;
    if (stale) shown = false; // old surface may be freed — nothing to erase
    const maxX = @as(i32, @intCast(d.w)) - @as(i32, SPR_W);
    const maxY = @as(i32, @intCast(d.h)) - @as(i32, SPR_H);
    const pre_x = cx;
    const pre_y = cy;
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    if (cx > maxX) cx = maxX;
    if (cy > maxY) cy = maxY;
    const clamped = (cx != pre_x or cy != pre_y);
    // Jump diagnostic (T590 oracle): per-tick delta + pre/post-clamp pos.
    // First 8 motion ticks verbosely, then every 16th — enough to see the
    // erratic pattern without flooding the listener at packet rate.
    // Every clamp event is marked separately (edge hit = suspect).
    if (moved and motionDiag) {
        diag_n += evs;
        if (diag_n <= 8 or moves % 16 == 0)
            sayU("cursor:ev dx={d} dy={d} pre={d},{d} pos={d},{d} clamp={d}\n",
                .{ last_dx, last_dy, pre_x, pre_y, cx, cy, @intFromBool(clamped) });
        if (clamped) {
            edge_n += 1;
            if (edge_n <= 8 or edge_n % 16 == 0) net.mark("cursor:edge");
        }
    }
    // Re-assert the sprite: erase at the last DRAWN pos (ox,oy — NOT the
    // just-updated cx,cy: hiding at the new pos XOR-cancelled the draw,
    // which is why the T590 arrow never appeared), then draw at the
    // current one. Runs on motion, on surface swap, and every 32nd idle
    // tick so console text printed under the sprite heals.
    tick_n += 1;
    const redraw = !sceneOwned and (moved or stale or !shown or (tick_n & 31) == 0);
    if (redraw) {
        if (shown) drawSprite(ox, oy); // XOR-erase at last drawn pos
        drawSprite(cx, cy);
        ox = cx;
        oy = cy;
        shown = true;
    }
    // UDP mirror on a stride + always the first motion so the oracle sees
    // the cursor alive immediately without flooding the listener.
    if (moved and motionDiag and (moves == 1 or moves % 16 == 0)) net.mark("cursor: move");
    return moved;
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
