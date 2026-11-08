// koru/native/earlyfb — pre-console framebuffer boot oracle.
//
// The T590 has no serial adapter and the caps LED never responds (dead
// 8042 channel on this EC), so the ONLY observability that works before
// net.init brings UDP up is the panel itself: GRUB hands the kernel a
// linear framebuffer via multiboot2 tag 8 and keeps scanning it until
// i915 modesets. This module adopts that fb right after faults.install
// — before pmm/net — using STATIC page tables (pmm and mmio.map don't
// exist yet), then draws BIG color-coded stage banners + text straight
// through fb.koruos_fb_* — no text.zig console dependency, no cursor.
//
// It also gives isrReport a panel-drawn fault vector: a post-IDT fault
// FREEZES on a red "FAULT vec=n" screen instead of triple-faulting back
// to GRUB. Combined with the dwell after each stage, a flash now shows
// exactly which milestone it died at.
//
// Outcome table:
//   GRUB menu persists, no KORU banner .... kernel never ran (bad flash)
//   frozen colored banner + "FAULT vec=" .. ran, faulted at that stage
//   banner stays on stage N, no more ...... ran, hung at stage N
//   banner reaches NIC + UDP markers ....... healthy to shell
//
// fb.init later re-adopts the SAME lfb through mmio.map — the epd[]
// tables installed here are reused (pdpt[gb] already nonzero), so the
// early markers and the console share one surface with no conflict.

const std = @import("std");
const fb = @import("fb.zig");
const text = @import("text.zig"); // for the shared 8x8 font only

extern var pdpt: [512]u64; // boot.zig — pd covers GB0 only
extern var pd: [512]u64;
extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;

// One 4 KiB pd per 1 GiB window, for hi windows pmm can't serve yet.
// Untouched entries stay not-present (loader-zeroed .bss). 8 windows
// = 0..8 GiB — the GRUB LFB lands ~0xFD000000 (GB3) on QEMU and in
// similar high stolen-memory on real HW.
var epd: [8][512]u64 align(4096) = [_][512]u64{[_]u64{0} ** 512} ** 8;

const Mb2Fb = extern struct {
    type: u32,
    size: u32,
    addr: u64,
    pitch: u32,
    width: u32,
    height: u32,
    bpp: u8,
    fb_type: u8,
    reserved: u16,
};

var adopted: bool = false; // fb externs live — raw draws are safe
var W: u32 = 0;
var H: u32 = 0;

// XRGB8888 colors (0x00RRGGBB).
const C_BLACK = @as(u32, 0x000000);
const C_WHITE = @as(u32, 0xFFFFFF);
const C_GREEN = @as(u32, 0x00FF00);
const C_YELLOW = @as(u32, 0xFFFF00);
const C_ORANGE = @as(u32, 0xFF8000);
const C_CYAN = @as(u32, 0x00FFFF);
const C_BLUE = @as(u32, 0x0080FF);
const C_RED = @as(u32, 0xFF0000);
const C_MAGENTA = @as(u32, 0xFF00FF);

fn stageColor(n: u32) u32 {
    return switch (n) {
        0 => C_GREEN,
        1 => C_YELLOW,
        2 => C_ORANGE,
        3 => C_CYAN,
        4 => C_BLUE,
        5 => C_MAGENTA,
        else => C_RED,
    };
}

// Walk mbi tags for the framebuffer info tag (8); returns a copy.
fn probe(mbi_phys: u32) ?Mb2Fb {
    if (mbi_phys == 0) return null;
    const base: [*]const u8 = @ptrFromInt(mbi_phys);
    const total = std.mem.readInt(u32, base[0..4], .little);
    var off: usize = 8;
    while (off + 8 <= total) {
        const t = std.mem.readInt(u32, base[off..][0..4], .little);
        const s = std.mem.readInt(u32, base[off + 4 ..][0..4], .little);
        if (t == 0) break;
        if (t == 8 and s >= @sizeOf(Mb2Fb)) {
            const f: *align(1) const Mb2Fb = @ptrCast(base + off);
            return f.*;
        }
        off += (s + 7) & ~@as(usize, 7); // tags are 8-byte aligned
    }
    return null;
}

// Identity-map [phys,phys+len) with 2 MiB pages, using the static epd[]
// tables for hi GBs. Mirrors mmio.map's entry format minus PCD —
// cached is fine for a brief boot log; fb.init re-maps PCD later.
fn mapWindow(phys: u64, len: u64) bool {
    const first = phys & ~@as(u64, 0x1FFFFF);
    const last = (phys + len + 0x1FFFFF) & ~@as(u64, 0x1FFFFF);
    var p = first;
    while (p < last) : (p += 0x200000) {
        const gb: usize = @intCast(p >> 30);
        if (gb >= epd.len) return false;
        var table: *[512]u64 = &pd;
        if (gb != 0) {
            if (pdpt[gb] == 0) {
                const taddr: u64 = @intCast(@intFromPtr(&epd[gb]));
                pdpt[gb] = (taddr & ~@as(u64, 0xFFF)) | 0x3;
            }
            table = @ptrFromInt(pdpt[gb] & ~@as(u64, 0xFFF));
        }
        table[(p >> 21) & 0x1FF] = p | 0x83; // P|RW|PS — 2 MiB, cached
    }
    asm volatile ("mov %cr3, %rax\n\tmov %rax, %cr3"
        :
        :
        : .{ .rax = true, .memory = true });
    return true;
}

// --- raw drawing (no text.zig console state needed) --------------------

fn rect(x: u32, y: u32, w: u32, h: u32, c: u32) void {
    _ = fb.koruos_fb_fill(x, y, w, h, c);
}

// One 8x8 font glyph blown up to scale×scale filled blocks — readable
// from across the room, and immune to the 1px text.zig cursor issues.
fn glyph(x: u32, y: u32, g: u8, s: u32, c: u32) void {
    const f = text.font[g & 0x7F];
    var r: usize = 0;
    while (r < 8) : (r += 1) {
        const bits = f[r];
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            if (((bits >> @intCast(col)) & 1) != 0) {
                rect(x + @as(u32, @intCast(col)) * s,
                     y + @as(u32, @intCast(r)) * s, s, s, c);
            }
        }
    }
}

// Draw a NUL-terminated string at (x,y), glyph cell = 8*s wide, 8*s tall
// plus s spacing. Returns the x where the next string would start.
fn bigText(x0: u32, y: u32, s: [*:0]const u8, scale: u32, c: u32) u32 {
    var x = x0;
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        glyph(x, y, s[i], scale, c);
        x += 9 * scale;
    }
    return x;
}

fn bigDec(x: u32, y: u32, v: u64, scale: u32, c: u32) u32 {
    // Render v in decimal: collect digits MSD-first into a small buffer.
    var tmp: [20]u8 = undefined;
    var cnt: usize = 0;
    var n = v;
    if (n == 0) {
        tmp[cnt] = '0';
        cnt += 1;
    } else {
        while (n != 0) : (n /= 10) {
            tmp[cnt] = @intCast('0' + n % 10);
            cnt += 1;
        }
    }
    var x2 = x;
    // tmp holds digits LSB-first — emit MSD-first by walking backwards.
    var i: usize = cnt;
    while (i != 0) {
        i -= 1;
        glyph(x2, y, tmp[i], scale, c);
        x2 += 9 * scale;
    }
    return x2;
}

// Approximate busy-wait so each stage stays readable before whatever
// comes next. ~0.6-1.0 s on KBL; slower under TCG (verification only).
fn dwell() void {
    var i: u64 = 350_000_000;
    while (i != 0) : (i -= 1) asm volatile ("pause");
}

// Clear the whole surface to black once the fb is adopted.
fn clearAll() void {
    rect(0, 0, W, H, C_BLACK);
}

// Adopt the loader's fb and draw the first banner. Runs right after
// faults.install so anything it does wrong FREEZES via the IDT.
pub fn init(mbi_phys: u32) void {
    const f = probe(mbi_phys) orelse {
        koru_say("efb: no mb2 tag8 — oracle blind\n");
        return;
    };
    if (f.bpp != 32 or f.fb_type != 1 or f.addr == 0
        or f.width == 0 or f.height == 0
        or f.width > 8192 or f.height > 8192) {
        koru_say("efb: tag8 unsupported — oracle blind\n");
        return;
    }
    // The oracle must NEVER crash the boot. Every fb.koruos_fb_* offset
    // is y*(pitch/4)+x — if pitch < width*4 a fill writes past the mapped
    // window, #PFs, and isrReport->earlyfb.fault repeats the same wild
    // write -> triple fault -> reset (the exact -1845 symptom: no marker,
    // bootloader, zero UDP). Reject anything that can't bound a row.
    if (f.pitch < f.width * 4 or f.pitch > 0x100000) {
        koru_say("efb: bad pitch — oracle blind\n");
        return;
    }
    const bytes = @as(u64, f.pitch) * @as(u64, f.height);
    if (bytes > 0x2000000) { // >32 MiB — not a real panel fb
        koru_say("efb: fb too large — oracle blind\n");
        return;
    }
    if (!mapWindow(f.addr, bytes)) {
        koru_say("efb: mapWindow refused — oracle blind\n");
        return;
    }
    fb.adoptRaw(f.addr, f.pitch, f.width, f.height);
    adopted = true;
    W = f.width;
    H = f.height;
    clearAll();
    koru_say("efb: live addr="); koru_putdec(f.addr);
    koru_say(" pitch="); koru_putdec(f.pitch);
    koru_say(" w="); koru_putdec(f.width);
    koru_say(" h="); koru_putdec(f.height); koru_say("\n");
    drawStage(0, "kernel-ran");
    dwell();
}

// Draw the persistent stage banner: a thick color band + big "STAGE n"
// + the stage name. Replaces the previous band each call (progress is
// visible as the band color changes down the boot).
fn drawStage(n: u32, name: [*:0]const u8) void {
    if (!adopted) return;
    const bandH: u32 = 56;
    const col = stageColor(n);
    rect(0, 0, W, bandH, col);          // top band = stage color
    rect(0, bandH, W, 6, C_BLACK);      // thin black separator
    // big "STAGE n" in black on the colored band (contrast either way)
    var tx: u32 = 24;
    tx = bigText(tx, 10, "STAGE ", 5, C_BLACK);
    tx = bigDec(tx, 10, n, 5, C_BLACK);
    // stage name below the band, white on black
    _ = bigText(24, bandH + 18, name, 3, C_WHITE);
    // serial echo for anyone attached
    koru_say("efb:S"); koru_putdec(n); koru_say(" "); koru_say(name); koru_say("\n");
}

pub fn stage(n: u32, name: [*:0]const u8) void {
    drawStage(n, name);
    dwell();
}

// Draw a frozen fault screen — called from faults.isrReport so a
// post-IDT exception parks on a big red FAULT banner + vector instead
// of resetting. Safe in fault context: only fb memory writes.
pub fn fault(vec: u64) void {
    if (!adopted) return;
    rect(0, 0, W, H, C_RED);
    var x: u32 = 24;
    x = bigText(x, 40, "FAULT vec=", 6, C_WHITE);
    x = bigDec(x, 40, vec, 6, C_WHITE);
    _ = bigText(24, 120, "frozen-no-reset", 3, C_WHITE);
    koru_say("efb:FAULT vec="); koru_putdec(vec); koru_say("\n");
}
