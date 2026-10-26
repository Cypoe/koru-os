// koru/native acpi — RSDP discovery + SDT table walk.
//
// Discovery is honest about where the pointer may live: multiboot2 tags
// 14/15 when a loader hands us a copy (the GRUB path), else the
// bare-metal scan — the EBDA head (segment at 0x40E) then the
// 0xE0000..0xFFFFF BIOS window, the only regions firmware may legally
// place "RSD PTR ". Under QEMU -kernel the loader gives no tag, so the
// scan IS the path — measured, not assumed.
//
// Every layer checks out by checksum: a descriptor or table that fails
// its sum is named corrupt, never silently trusted. Consumers ask
// findTable("APIC") — SMP's MADT and shutdown's FACP are names this
// walk already resolved; parsing their payloads is their own cell.

const std = @import("std");

extern fn koru_say(s: [*:0]const u8) void;

fn say(s: [*:0]const u8) void {
    koru_say(s);
}
fn sig4(sig: *const [4]u8) void {
    var b: [5]u8 = .{ sig[0], sig[1], sig[2], sig[3], 0 };
    koru_say(@ptrCast(&b));
}
fn hexw(v: u64, comptime w: usize) void {
    var buf: [w + 1]u8 = undefined;
    buf[w] = 0;
    var i: usize = 0;
    while (i < w) : (i += 1) {
        const nib = (v >> @intCast(4 * (w - 1 - i))) & 0xF;
        buf[i] = "0123456789abcdef"[@intCast(nib)];
    }
    koru_say(@ptrCast(&buf));
}
fn sayf(comptime fmt: []const u8, args: anytype) void {
    var buf: [192]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    koru_say(s.ptr);
}

// ---- RSDP ------------------------------------------------------------

const RSDP_SIG = "RSD PTR ";

fn sum8(p: [*]const u8, n: usize) u8 {
    var s: u8 = 0;
    for (p[0..n]) |b| s +%= b;
    return s;
}

fn rd16(p: [*]const u8, off: usize) u16 {
    return std.mem.readInt(u16, p[off..][0..2], .little);
}
fn rd32(p: [*]const u8, off: usize) u32 {
    return std.mem.readInt(u32, p[off..][0..4], .little);
}
fn rd64(p: [*]const u8, off: usize) u64 {
    return std.mem.readInt(u64, p[off..][0..8], .little);
}

// Valid RSDP at `pa`? Signature + v1 checksum (20 bytes); for rev>=2 the
// extended checksum covers the whole descriptor.
fn rsdpAt(pa: u64) bool {
    const p: [*]const u8 = @ptrFromInt(pa);
    if (!std.mem.eql(u8, p[0..8], RSDP_SIG)) return false;
    if (sum8(p, 20) != 0) return false;
    if (p[15] >= 2) {
        const len = rd32(p, 20);
        if (len < 36 or len > 4096 or sum8(p, len) != 0) return false;
    }
    return true;
}

// mb2 tags 14 (ACPIv2 RSDP) / 15 (ACPIv1) carry a COPY of the descriptor
// after the 8-byte tag header — walk the info block when one exists.
fn rsdpFromMb2(mbi_phys: u32) ?u64 {
    if (mbi_phys == 0) return null;
    const base: [*]const u8 = @ptrFromInt(mbi_phys);
    const total = rd32(base, 0);
    if (total < 16 or total > 16 * 1024 * 1024) return null;
    var off: usize = 8;
    while (off + 8 <= total) {
        const t = rd32(base, off);
        const sz = (rd32(base, off + 4) + 7) & ~@as(u32, 7);
        if (t == 0) break;
        if ((t == 14 or t == 15) and sz >= 8 + 20) {
            const pa: u64 = mbi_phys + off + 8;
            if (rsdpAt(pa)) return pa;
        }
        off += sz;
    }
    return null;
}

fn rsdpScan(lo: u64, hi: u64) ?u64 {
    var a = lo;
    while (a + 36 <= hi) : (a += 16) {
        if (rsdpAt(a)) return a;
    }
    return null;
}

// ---- SDT walk --------------------------------------------------------

pub const Table = struct { sig: [4]u8, phys: u64, len: u32 };

pub const MAXTABLES = 32;
pub var tables: [MAXTABLES]Table = undefined;
pub var ntables: usize = 0;
pub var found: bool = false;

fn regTable(pa: u64) void {
    if (ntables >= MAXTABLES) return;
    const p: [*]const u8 = @ptrFromInt(pa);
    const len = rd32(p, 4);
    if (len < 36 or len > 16 * 1024 * 1024) {
        sayf("acpi: table @{x} len={d} — corrupt, skipped\n", .{ pa, len });
        return;
    }
    if (sum8(p, len) != 0) {
        say("acpi: ");
        sig4(p[0..4]);
        sayf(" @{x} checksum fail — corrupt, skipped\n", .{pa});
        return;
    }
    tables[ntables] = .{ .sig = .{ p[0], p[1], p[2], p[3] }, .phys = pa, .len = len };
    ntables += 1;
}

pub fn findTable(sig: *const [4]u8) ?Table {
    for (tables[0..ntables]) |t| {
        if (std.mem.eql(u8, &t.sig, sig)) return t;
    }
    return null;
}

pub fn init(mbi_phys: u32) void {
    // Loader copy first, then the two legal firmware regions.
    var rsdp = rsdpFromMb2(mbi_phys);
    if (rsdp == null) {
        const bda: [*]const u8 = @ptrFromInt(0x40E);
        const ebda = @as(u64, rd16(bda, 0)) << 4;
        if (ebda >= 0x80000 and ebda < 0xA0000)
            rsdp = rsdpScan(ebda, ebda + 1024);
    }
    if (rsdp == null)
        rsdp = rsdpScan(0xE0000, 0x100000);
    const rp = rsdp orelse {
        say("acpi: REFUSED — no RSDP (no mb2 tag, no BIOS signature)\n");
        return;
    };

    const p: [*]const u8 = @ptrFromInt(rp);
    const rev = p[15];
    say("acpi: rsdp@");
    hexw(rp, 8);
    sayf(" rev={d} oem={s}\n", .{ rev, p[9..15] });

    // v2+ names the XSDT (64-bit entries); v1 the RSDT (32-bit).
    var root: u64 = undefined;
    var stride: usize = 8;
    if (rev >= 2) {
        root = rd64(p, 24);
        say("acpi: xsdt ");
    } else {
        root = rd32(p, 16);
        stride = 4;
        say("acpi: rsdt ");
    }
    hexw(root, 8);
    say("\n");

    const sp: [*]const u8 = @ptrFromInt(root);
    const slen = rd32(sp, 4);
    if (slen < 36 or sum8(sp, slen) != 0) {
        say("acpi: REFUSED — root SDT corrupt\n");
        return;
    }
    var off: usize = 36;
    while (off + stride <= slen) : (off += stride) {
        const tpa = if (stride == 8) rd64(sp, off) else rd32(sp, off);
        if (tpa != 0) regTable(tpa);
    }
    found = ntables > 0;

    sayf("acpi: tables={d}", .{ntables});
    for (tables[0..ntables]) |t| {
        say(" ");
        sig4(&t.sig);
    }
    say("\n");
}
