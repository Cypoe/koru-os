// koru/native/efault — bulletproof pre-console fault + stage oracle.
//
// Why this exists: real-HW boots kept returning to GRUB with zero UDP.
// Two unknowns remained — (a) did the kernel even run far enough to map a
// framebuffer, and (b) if it faulted, WHERE. faults.zig freezes exceptions
// but reports them only via serial + the fb text console — both of which
// ride on subsystems (pmm/mmio/fb/text) that can themselves be the thing
// that crashed. This module removes every such dependency:
//
//   * the GRUB tag-8 LFB is mapped with STATIC .bss page tables installed
//     straight into pdpt[]/pd[] — no pmm.alloc, no mmio.map, no fb.zig.
//   * pixels are raw volatile u32 writes at VA==phys, bounded to the
//     tag-8 geometry so a bad pitch/dim can never write out of the window.
//   * stage markers are solid colour bands + a tiny hex/dec font — readable
//     from across the room, no font/text-console state.
//   * isrReport calls reportFault(); a re-entrant fault sees inReport and
//     returns without touching the fb, so a fault INSIDE the fb write
//     freezes the machine instead of recursing into a triple fault.
//
// Outcome on the panel:
//   GRUB menu frozen, no bands ........ kernel never ran / died pre-S0
//   bands lit up to Sk ................ died entering stage k+1
//   solid red + "VEC nn / CR2 hhhh" ... catchable exception — vector names it
//   menu redraws in a loop ............ triple fault / reset (pre-IDT or #DF)

const std = @import("std");

extern var pdpt: [512]u64; // boot.zig — pd[] owns GB0; we extend hi GBs here
extern var pd: [512]u64;   // boot.zig — GB0 identity 2 MiB table

extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;

// ---- multiboot2 tag-8 framebuffer --------------------------------------

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

fn probeTag8(mbi_phys: u32) ?Mb2Fb {
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

// ---- static hi-memory page tables (no pmm, no allocator) ----------------
// The boot pd[] covers GB0 only. A GRUB LFB can sit in any GB (QEMU puts it
// at 0xFD000000 = GB3). We keep a small pool of 4 KiB pd tables in .bss and
// install them into pdpt[gb] ourselves. Later mmio.map for the same gb
// sees pdpt[gb] != 0 and SHARES our table — both mappings coexist, nothing
// is evicted. .bss is inside pmm's reserved [1MiB,_end) so these tables are
// never handed to the frame allocator.

var efb_pd: [4][512]u64 align(4096) = undefined;
var efb_pd_gb: [4]i64 = .{ -1, -1, -1, -1 }; // which GB each table serves
var efb_pd_used: usize = 0;

// Resolve (and if needed install) the 512-entry pd covering 1 GiB `gb`.
fn tableForGb(gb: u64) ?[*]u64 {
    if (gb >= 512) return null;
    if (gb == 0) return @ptrCast(&pd); // GB0 already has the identity table
    for (efb_pd_gb, 0..) |g, i| {
        if (g == @as(i64, @intCast(gb))) return @ptrCast(&efb_pd[i]);
    }
    if (efb_pd_used >= efb_pd.len) return null;
    const i = efb_pd_used;
    efb_pd_used += 1;
    efb_pd_gb[i] = @intCast(gb);
    @memset(&efb_pd[i], 0);
    // pdpt[gb] = phys addr of the new pd | present|rw. Our tables are in
    // low .bss which is identity-mapped, so VA == PA here.
    pdpt[gb] = @intFromPtr(&efb_pd[i]) | 0x3;
    return @ptrCast(&efb_pd[i]);
}

// Identity-map every 2 MiB page covering [addr, addr+len) with PCD leaf
// entries (0x93 = present|rw|PCD|PS), then flush the TLB via CR3.
fn mapFb(addr: u64, len: u64) bool {
    const first = addr & ~@as(u64, 0x1FFFFF);
    const last = (addr + len + 0x1FFFFF) & ~@as(u64, 0x1FFFFF);
    var p = first;
    while (p < last) : (p += 0x200000) {
        const t = tableForGb(p >> 30) orelse return false;
        t[@intCast((p >> 21) & 0x1FF)] = p | 0x93;
    }
    asm volatile ("mov %%cr3, %%rax\n\tmov %%rax, %%cr3"
        :
        :
        : .{ .rax = true, .memory = true });
    return true;
}

// ---- fb state + raw drawing --------------------------------------------

var adopted: bool = false;
var inReport: bool = false; // recursion guard — set before any fault draw
var fb32: [*]volatile u32 = undefined; // VA==phys base of the LFB
var pitchU32: u32 = 0; // pitch in u32 pixels (pitch bytes / 4)
var fw: u32 = 0;
var fh: u32 = 0;
var fbBytes: u64 = 0;

fn px(x: u32, y: u32, c: u32) void {
    if (x >= fw or y >= fh) return;
    const idx = @as(u64, y) * pitchU32 + x;
    if (idx * 4 >= fbBytes) return; // never write past the mapped window
    fb32[@intCast(idx)] = c;
}

fn rect(x: u32, y: u32, w: u32, h: u32, c: u32) void {
    var yy = y;
    const y1 = @min(y + h, fh);
    while (yy < y1) : (yy += 1) {
        var xx = x;
        const x1 = @min(x + w, fw);
        while (xx < x1) : (xx += 1) px(xx, yy, c);
    }
}

// ---- tiny 3x5 font: hex digits + the two label letters we need ----------
// Index: 0-9 digits, 10-15 A-F, 16 'V', 17 'R'. Each glyph is 5 rows of
// 3 bits; bit0 = leftmost column. Enough for "VEC nn" and a 16-digit CR2.

const font: [18][5]u8 = .{
    .{ 0b111, 0b101, 0b101, 0b101, 0b111 }, // 0
    .{ 0b010, 0b110, 0b010, 0b010, 0b111 }, // 1
    .{ 0b111, 0b001, 0b111, 0b100, 0b111 }, // 2
    .{ 0b111, 0b001, 0b111, 0b001, 0b111 }, // 3
    .{ 0b101, 0b101, 0b111, 0b001, 0b001 }, // 4
    .{ 0b111, 0b100, 0b111, 0b001, 0b111 }, // 5
    .{ 0b111, 0b100, 0b111, 0b101, 0b111 }, // 6
    .{ 0b111, 0b001, 0b001, 0b010, 0b010 }, // 7
    .{ 0b111, 0b101, 0b111, 0b101, 0b111 }, // 8
    .{ 0b111, 0b101, 0b111, 0b001, 0b111 }, // 9
    .{ 0b010, 0b101, 0b111, 0b101, 0b101 }, // A
    .{ 0b110, 0b101, 0b110, 0b101, 0b110 }, // B
    .{ 0b011, 0b100, 0b100, 0b100, 0b011 }, // C
    .{ 0b110, 0b101, 0b101, 0b101, 0b110 }, // D
    .{ 0b111, 0b100, 0b110, 0b100, 0b111 }, // E
    .{ 0b111, 0b100, 0b110, 0b100, 0b100 }, // F
    .{ 0b101, 0b101, 0b101, 0b101, 0b010 }, // V
    .{ 0b110, 0b101, 0b110, 0b101, 0b101 }, // R
};

fn glyphIndex(ch: u8) ?usize {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'A' and ch <= 'F') return 10 + (ch - 'A');
    if (ch == 'V') return 16;
    if (ch == 'R') return 17;
    return null;
}

fn glyph(x: u32, y: u32, ch: u8, s: u32, c: u32) void {
    const gi = glyphIndex(ch) orelse return;
    for (font[gi], 0..) |row, ry| {
        for (0..3) |col| {
            if (((row >> @intCast(col)) & 1) != 0)
                rect(x + @as(u32, @intCast(col)) * s,
                     y + @as(u32, @intCast(ry)) * s, s, s, c);
        }
    }
}

// Draw a NUL-terminated string; returns end x. Only glyphs in `font` show.
fn text(x0: u32, y: u32, s: [*:0]const u8, scale: u32, c: u32) u32 {
    var x = x0;
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) {
        glyph(x, y, s[i], scale, c);
        x += 4 * scale;
    }
    return x;
}

fn dec(x: u32, y: u32, v: u64, scale: u32, c: u32) u32 {
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
    var cx = x;
    var i = cnt;
    while (i != 0) {
        i -= 1;
        glyph(cx, y, tmp[i], scale, c);
        cx += 4 * scale;
    }
    return cx;
}

fn hex(x: u32, y: u32, v: u64, digits: u32, scale: u32, c: u32) u32 {
    var cx = x;
    var i = digits;
    while (i != 0) {
        i -= 1;
        const d = (v >> @as(u6, @intCast(i * 4))) & 0xF;
        const ch: u8 = if (d < 10) @intCast('0' + d) else @intCast('A' + (d - 10));
        glyph(cx, y, ch, scale, c);
        cx += 4 * scale;
    }
    return cx;
}

// ---- public surface ------------------------------------------------------

const C_GREEN = 0x0000FF00;
const C_CYAN = 0x0000FFFF;
const C_BLUE = 0x000000FF;
const C_MAGENTA = 0x00FF00FF;
const C_YELLOW = 0x00FFFF00;
const C_RED = 0x00FF0000;
const C_WHITE = 0x00FFFFFF;
const C_BLACK = 0x00000000;

fn stageColor(n: u32) u32 {
    return switch (n) {
        0 => C_GREEN,
        1 => C_CYAN,
        2 => C_BLUE,
        3 => C_MAGENTA,
        4 => C_YELLOW,
        else => C_WHITE,
    };
}

// Adopt the loader fb and draw S0 (kernel-ran). Called from kmain right
// after faults.install — before pmm/net so a fault in either is bracketed.
pub fn init(mbi_phys: u32) void {
    const f = probeTag8(mbi_phys) orelse {
        koru_say("efault: no mb2 tag8 — oracle blind\n");
        return;
    };
    if (f.bpp != 32 or f.fb_type != 1 or f.addr == 0
        or f.width == 0 or f.height == 0
        or f.width > 8192 or f.height > 8192
        or f.pitch < f.width * 4 or f.pitch > 0x100000) {
        koru_say("efault: tag8 geometry rejected — oracle blind\n");
        return;
    }
    const bytes = @as(u64, f.pitch) * @as(u64, f.height);
    if (bytes == 0 or bytes > 0x2000000) {
        koru_say("efault: fb size rejected — oracle blind\n");
        return;
    }
    if (!mapFb(f.addr, bytes)) {
        koru_say("efault: LFB map refused — oracle blind\n");
        return;
    }
    fb32 = @ptrFromInt(@as(usize, @intCast(f.addr))); // identity VA==phys
    pitchU32 = f.pitch / 4;
    fw = f.width;
    fh = f.height;
    fbBytes = bytes;
    adopted = true;
    koru_say("efault: fb live addr=");
    koru_putdec(f.addr);
    koru_say(" pitch=");
    koru_putdec(f.pitch);
    koru_say(" w=");
    koru_putdec(f.width);
    koru_say(" h=");
    koru_putdec(f.height);
    koru_say("\n");
    mark(0); // S0 kernel-ran
}

// Draw stage n as a colour block in the top progress strip + its number.
// Blocks accumulate left-to-right; the rightmost lit block is the furthest
// stage reached. No-op until adopted.
pub fn mark(n: u32) void {
    if (!adopted) return;
    const stripH: u32 = 96;
    const bw: u32 = @max(fw / 8, 1);
    rect(n * bw, 0, bw, stripH, stageColor(n));
    rect(n * bw, stripH, bw, 4, C_BLACK);
    _ = dec(n * bw + 8, 30, n, 8, C_BLACK);
    koru_say("efault:S");
    koru_putdec(n);
    koru_say("\n");
}

// Steady "survived" marker after the last stage — a white bottom border.
pub fn finish() void {
    if (!adopted) return;
    rect(0, fh - 12, fw, 12, C_WHITE);
    koru_say("efault: all stages reached\n");
}

// True once a fault report has started drawing — isrReport uses this to
// skip serial/LED work on a nested fault so the fb path can't recurse.
pub fn busy() bool {
    return inReport;
}

// Draw the fault screen. Called from faults.isrReport. Returns without
// touching the fb when the oracle is blind or already reporting, so a
// fault INSIDE these writes freezes cleanly instead of triple-faulting.
pub fn reportFault(vec: u64, cr2: u64) void {
    if (!adopted or inReport) return;
    inReport = true;
    rect(0, 0, fw, fh, C_RED);
    const x: u32 = text(40, 60, "VEC", 8, C_WHITE);
    _ = dec(x + 24, 60, vec, 8, C_WHITE);
    const y2: u32 = text(40, 200, "CR2", 8, C_WHITE);
    _ = hex(y2 + 96, 200, cr2, 16, 4, C_YELLOW);
    koru_say("efault:FAULT vec=");
    koru_putdec(vec);
    koru_say(" cr2=");
    koru_putdec(cr2);
    koru_say("\n");
}
