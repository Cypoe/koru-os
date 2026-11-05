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

// ---- IO ---------------------------------------------------------------

fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (port),
        : .{ .memory = true });
}
fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
        : .{ .memory = true });
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

    parseMadt();
    parseFadt();
}

// ---- MADT ("APIC") — the SMP consumer's directory ----------------------
//
// The header's lapic_addr is the CR3-independent default; entries list
// per-CPU local APICs (type 0 — the enable bit is real state), I/O
// APICs (type 1), and interrupt-source overrides (type 2 — the legacy
// IRQ→GSI remaps that make "IRQ1 is vector N" a table answer, not a
// guess). Stored, not just printed: SMP's AP bringup reads these rows.

pub var lapicPhys: u64 = 0;
pub var ncpus: usize = 0;
pub var ncpusEnabled: usize = 0;
pub var nioapics: usize = 0;
pub var isos: usize = 0;
// First I/O APIC's phys + GSI base, and the interrupt-source overrides
// — the ISA->GSI remaps (IRQ0 is pin 2 on i440fx) plus polarity/trigger
// overrides (PCI shares level-low). ioapic.zig owns the door; these are
// just the names.
pub var ioapicPhys: u64 = 0;
pub var ioapicGsiBase: u32 = 0;
pub const Iso = struct { src: u8, gsi: u32, flags: u16 };
pub var isoList: [32]Iso = undefined;
// LAPIC ids of the counted CPUs — IPI targets for bringup. 64 is a
// stated bound, not a guess: past it the count still reports honestly
// and the id array simply doesn't cover the tail.
pub var apicIds: [64]u8 = undefined;

fn parseMadt() void {
    const t = findTable("APIC") orelse {
        say("madt: absent — no APIC table\n");
        return;
    };
    const p: [*]const u8 = @ptrFromInt(t.phys);
    lapicPhys = rd32(p, 36);
    var off: usize = 44;
    while (off + 2 <= t.len) {
        const etype = p[off];
        const elen = p[off + 1];
        if (elen < 2 or off + elen > t.len) break;
        switch (etype) {
            0 => {
                if (ncpus < 64) apicIds[ncpus] = p[off + 3];
                ncpus += 1;
                if (elen >= 8 and (rd32(p, off + 4) & 1) != 0) ncpusEnabled += 1;
            },
            1 => {
                if (nioapics == 0 and elen >= 12) {
                    ioapicPhys = rd32(p, off + 4);
                    ioapicGsiBase = rd32(p, off + 8);
                }
                nioapics += 1;
            },
            2 => {
                if (isos < 32 and elen >= 10)
                    isoList[isos] = .{
                        .src = p[off + 3],
                        .gsi = rd32(p, off + 4),
                        .flags = rd16(p, off + 8),
                    };
                isos += 1;
            },
            else => {},
        }
        off += elen;
    }
    sayf("madt: lapic={x} cpus={d}({d}en) ioapics={d} isos={d}\n", .{
        lapicPhys, ncpus, ncpusEnabled, nioapics, isos,
    });
}

// ---- FADT ("FACP") + _S5 — the power door ------------------------------
//
// Shutdown is a real register write, not a hack: PM1a_CNT_BLK comes
// from the FADT, the S5 sleep type comes from the DSDT's \_S5 package —
// the same two values firmware uses. The AML needed is one NameOp
// naming "_S5_" at root and a small PackageOp of two byte constants —
// decoded honestly (package length varint, BytePrefix/ZeroOp/OneOp
// elements), not a magic constant.

pub var pm1aCntBlk: u16 = 0;
pub var s5Typa: u8 = 0;
pub var s5Typb: u8 = 0;
pub var s5Found: bool = false;

// Decode one AML integer element; returns value + bytes consumed.
fn amlInt(p: [*]const u8, n: usize) ?struct { v: u8, n: usize } {
    if (n == 0) return null;
    return switch (p[0]) {
        0x00 => .{ .v = 0, .n = 1 }, // ZeroOp
        0x01 => .{ .v = 1, .n = 1 }, // OneOp
        0x0A => if (n >= 2) .{ .v = p[1], .n = 2 } else null, // BytePrefix
        else => null,
    };
}

// AML PkgLength: low 2 bits of the first byte say how many follow bytes
// carry the rest of the length (6-bit lead when zero).
fn pkgLen(p: [*]const u8, n: usize) ?struct { v: usize, n: usize } {
    if (n == 0) return null;
    const lead = p[0] >> 6;
    if (lead == 0) return .{ .v = p[0] & 0x3F, .n = 1 };
    var v: usize = p[0] & 0x0F;
    var i: usize = 0;
    while (i < lead) : (i += 1) {
        if (i + 1 >= n) return null;
        v |= @as(usize, p[i + 1]) << (4 + @as(u5, @intCast(i * 8)));
    }
    return .{ .v = v, .n = 1 + lead };
}

fn parseS5(dsdt: u64, dlen: u32) void {
    const p: [*]const u8 = @ptrFromInt(dsdt);
    var i: usize = 36; // AML starts after the SDT header
    while (i + 6 < dlen) : (i += 1) {
        // NameOp(0x08) [optional root prefix 0x5C] "_S5_"
        if (p[i] != 0x08) continue;
        var j = i + 1;
        if (p[j] == 0x5C) j += 1;
        if (!std.mem.eql(u8, p[j .. j + 4], "_S5_")) continue;
        j += 4;
        if (j >= dlen or p[j] != 0x12) return; // not a package — odd
        j += 1;
        const pl = pkgLen(p + j, dlen - j) orelse return;
        j += pl.n;
        if (j >= dlen) return;
        const nEl = p[j];
        j += 1;
        if (nEl < 2) return;
        const a = amlInt(p + j, dlen - j) orelse return;
        const b = amlInt(p + j + a.n, dlen - j - a.n) orelse return;
        s5Typa = a.v;
        s5Typb = b.v;
        s5Found = true;
        return;
    }
}

fn parseFadt() void {
    const t = findTable("FACP") orelse {
        say("fadt: absent — no power block\n");
        return;
    };
    const p: [*]const u8 = @ptrFromInt(t.phys);
    const dsdt = rd32(p, 40);
    pm1aCntBlk = @truncate(rd32(p, 64));
    if (dsdt != 0) parseS5(dsdt, rd32(@ptrFromInt(dsdt), 4));
    sayf("fadt: pm1a={x} dsdt@{x} s5 typa={d} typb={d}{s}\n", .{
        pm1aCntBlk, dsdt, s5Typa, s5Typb,
        if (s5Found) "" else " (no _S5 package)",
    });
}

// The kernel's power door. state 5 = S5 poweroff (PM1_CNT SLP_EN +
// firmware's own sleep type — QEMU exits); state 1 = reboot (8042
// pulse, triple-fault fallback). Never returns on success; a negative
// errno-style code names the refusal when the tables gave us nothing.
pub export fn koruos_powerctl(state: u32) callconv(.c) i32 {
    switch (state) {
        5 => {
            if (!s5Found or pm1aCntBlk == 0) return -38; // ENOSYS
            say("acpi: powerctl S5 pm1a=");
            hexw(pm1aCntBlk, 4);
            sayf(" typa={d} — power off\n", .{s5Typa});
            outw(pm1aCntBlk, (@as(u16, s5Typa) << 10) | (1 << 13));
            return 0; // a machine that ignored SLP_EN is still here
        },
        1 => {
            say("acpi: powerctl reboot — 8042 pulse\n");
            // 8042 reset line; if the chipset ignores it, triple fault
            var i: usize = 0;
            while (i < 100) : (i += 1) outb(0x64, 0xFE);
            const dead = extern struct { limit: u16 = 0, base: u64 = 0 }{};
            asm volatile ("lidt %[d]\n\tint3"
                :
                : [d] "m" (dead),
            );
            return 0;
        },
        else => return -22, // EINVAL
    }
}
