// koru/native runtime — the freestanding provider for the `koru-native` arm.
//
// The emitted backend declares this contract as externs and nothing else:
//   posix_memalign/free   the flow-prologue bare allocator (__koru_bare)
//   fputs/stdout/stderr   __kout when builtin.os.tag == .freestanding
// A native image compiles this file next to the emitted backend; the two
// `koruos/realize:row` declarations in index.kz bind the koru.runtime and
// std.io:print rows to it.
//
// Console is COM1 (115200 8N1): the one sink that exists on real hardware,
// QEMU (-serial), and a debug board alike — deliberately not isa-debugcon
// (0x402), which is QEMU-only even among the Unikraft platforms.
//
// Honest bound: the heap is a linear bump allocator — `free` is a no-op.
// Boot programs allocate and run; reclamation arrives with the spawn
// address-space seam (a domain teardown frees the bump region wholesale).

const std = @import("std");

const COM1: u16 = 0x3F8;

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
        : .{ .memory = true });
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
        : .{ .memory = true });
}

var serial_ready = false;

fn serInit() void {
    if (serial_ready) return;
    serial_ready = true;
    outb(COM1 + 1, 0x00); // interrupts off
    outb(COM1 + 3, 0x80); // DLAB: divisor latch
    outb(COM1 + 0, 0x01); // 115200 baud
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03); // 8N1
    outb(COM1 + 2, 0xC7); // FIFO on, 14-byte trigger
    outb(COM1 + 4, 0x0B); // DTR + RTS + OUT2
}

pub export fn serPut(c: u8) callconv(.c) void {
    while (inb(COM1 + 5) & 0x20 == 0) {} // wait for empty THR
    outb(COM1, c);
}

// ---- console contract -----------------------------------------------------

// fd-like tokens so a future multi-sink provider can distinguish the streams.
pub export var stdout: ?*anyopaque = @ptrFromInt(1);
pub export var stderr: ?*anyopaque = @ptrFromInt(2);

// wire_sink — optional mirror for program console output. The interactive
// native image sets this to route program bytes to the UDP telemetry wire
// (net.mirror) so Koru-program output is observable on real hardware where
// COM1 has no attached serial. Null in single-program images -> serial only.
pub var wire_sink: ?*const fn (s: [*]const u8, n: usize) void = null;

fn mirrorWire(s: [*]const u8, n: usize) void {
    if (wire_sink) |m| m(s, n);
}

// fputc emits one char at a time — mirror it through a line buffer flushed
// on '\n' (or when full) so char-wise print paths still reach the wire
// without one datagram per character.
var wc_buf: [256]u8 = undefined;
var wc_len: usize = 0;

fn wcFlush() void {
    if (wc_len == 0) return;
    mirrorWire(wc_buf[0..wc_len].ptr, wc_len);
    wc_len = 0;
}

fn wcPut(ch: u8) void {
    if (ch == '\n') {
        wcFlush();
        return;
    }
    if (wc_len >= wc_buf.len) wcFlush();
    wc_buf[wc_len] = ch;
    wc_len += 1;
}

pub export fn fputs(s: [*:0]const u8, stream: ?*anyopaque) callconv(.c) c_int {
    _ = stream;
    serInit();
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {
        if (s[n] == '\n') serPut('\r');
        serPut(s[n]);
    }
    wcFlush(); // ordered before this string's mirror
    mirrorWire(s, n);
    return @intCast(n);
}

// fputc — same serial sink; LLVM/std paths emit it for char-wise output.
pub export fn fputc(c: c_int, stream: ?*anyopaque) callconv(.c) c_int {
    _ = stream;
    serInit();
    const ch: u8 = @intCast(@as(u32, @bitCast(c)) & 0xFF);
    if (ch == '\n') serPut('\r');
    serPut(ch);
    wcPut(if (ch == '\r') '\n' else ch);
    return c;
}

// write(2) — the fd is a token like stdout's; all fds route to serial.
pub export fn write(fd: c_int, buf: [*]const u8, n: usize) callconv(.c) isize {
    _ = fd;
    serInit();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (buf[i] == '\n') serPut('\r');
        serPut(buf[i]);
    }
    wcFlush();
    mirrorWire(buf, n);
    return @intCast(n);
}

// LLVM lowers fputs→fwrite for computable lengths — provide it or the
// symbol dangles. Bytes go to the same serial sink; stream is ignored.
pub export fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: ?*anyopaque) callconv(.c) usize {
    _ = stream;
    serInit();
    const n = size * nmemb;
    for (0..n) |i| {
        if (ptr[i] == '\n') serPut('\r');
        serPut(ptr[i]);
    }
    wcFlush();
    mirrorWire(ptr, n);
    return nmemb;
}

// ---- heap contract --------------------------------------------------------

const HEAP_SIZE = 4 * 1024 * 1024 - 256 * 1024; // 3.75 MiB — .bss shrink: real-HW
// boot crashes when _end crosses ~0x6C9918-0x6D1918 (size/layout boundary,
// QEMU tolerates). 256 KiB of heap slack pulls _end ~192 KiB under the
// working threshold while keeping all M1 code; shell path never touches
// the bump heap (only prog.main's __koru_bare does).
var heap: [HEAP_SIZE]u8 align(4096) = undefined;
var heap_off: usize = 0;

pub export fn posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) callconv(.c) c_int {
    if (alignment == 0 or (alignment & (alignment - 1)) != 0 or alignment % @sizeOf(usize) != 0)
        return 22; // EINVAL
    if (size == 0) {
        memptr.* = null;
        return 0;
    }
    const base = @intFromPtr(&heap);
    const aligned = (base + heap_off + alignment - 1) & ~(alignment - 1);
    const off = aligned - base;
    if (off + size > HEAP_SIZE) return 12; // ENOMEM
    heap_off = off + size;
    memptr.* = @ptrFromInt(aligned);
    return 0;
}

pub export fn free(ptr: ?*anyopaque) callconv(.c) void {
    _ = ptr;
}

// malloc/memalign are the same bump allocator under different spellings —
// the ext2 lift externs these names (Unikraft's uk_alloc vocabulary).
pub export fn malloc(size: usize) callconv(.c) ?*anyopaque {
    var p: ?*anyopaque = null;
    if (posix_memalign(&p, 16, size) != 0) return null;
    return p;
}
pub export fn memalign(alignment: usize, size: usize) callconv(.c) ?*anyopaque {
    var p: ?*anyopaque = null;
    if (posix_memalign(&p, alignment, size) != 0) return null;
    return p;
}
// Opaque allocator token — the lift only threads it through QueueConf.a;
// the native queue_configure ignores it, so any non-null value serves.
pub export var _uk_alloc_head: ?*anyopaque = @ptrFromInt(1);

// ---- clock contract -------------------------------------------------------

// ukplat_monotonic_clock() -> u64 ns — what koruos/nid, koruos/slice and
// koruos/spawn extern. Implemented on the TSC, calibrated once at first
// read against the i8253 PIT channel 2 (1.193182 MHz, always present):
// no guessed frequency, no boot input. Honest bounds: monotonic ticks on
// the boot CPU only (unsynchronized across cores, TSC-invariant assumed),
// ~10 ms calibration stall once, PIT-window accuracy.
const PIT_CH2: u16 = 0x42;
const PIT_MODE: u16 = 0x43;
const PC_SPEAKER: u16 = 0x61;
const PIT_HZ: u64 = 1_193_182;

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        :
        : .{ .memory = true });
    return (@as(u64, hi) << 32) | lo;
}

var tsc_hz: u64 = 0;

fn calibrateTsc() u64 {
    if (tsc_hz != 0) return tsc_hz;
    const window: u64 = 11932; // ~10 ms at 1.193182 MHz
    const sb = inb(PC_SPEAKER);
    outb(PC_SPEAKER, (sb & 0xFC) | 0x01); // ch2 gate on, speaker off
    outb(PIT_MODE, 0xB0); // ch2, lobyte/hibyte, mode 0 (one-shot)
    outb(PIT_CH2, @truncate(window));
    outb(PIT_CH2, @truncate(window >> 8));
    const t0 = rdtsc();
    while (inb(PC_SPEAKER) & 0x20 == 0) {} // OUT rises at terminal count
    tsc_hz = (rdtsc() - t0) * PIT_HZ / window;
    return tsc_hz;
}

pub export fn ukplat_monotonic_clock() callconv(.c) u64 {
    const hz = calibrateTsc();
    const t = rdtsc();
    // t/hz ~ seconds; split so the remainder term cannot overflow u64.
    return (t / hz) * 1_000_000_000 + (t % hz) * 1_000_000_000 / hz;
}

// ---- nid object-pin store (koruos/nid's native realization) ---------------
// Providers pin (foreign-name → provider-local key) and get the minted nid:
// the object's resolvable identity, derived from the object itself (e.g.
// ext2/d0/<ino>), so a path rename re-mints the same nid and the binding
// survives the view. nid==0 is refusal — collisions and key conflicts are
// loud, never resolved by first-come. Arms without this provider refuse at
// link: the symbols are the seam.

const ObjPin = struct { foreign: [64]u8, flen: u8, nid: u64, key: u64 };
var objpins: [64]ObjPin = undefined;
var n_objpins: usize = 0;

fn nidHash(foreign: []const u8) u64 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("koruos.nid.v1|");
    h.update(foreign);
    var d: [32]u8 = undefined;
    h.final(&d);
    return std.mem.readInt(u64, d[0..8], .big);
}

fn nidLog(comptime f: []const u8, a: anytype) void {
    var b: [1024]u8 = undefined;
    const s = std.fmt.bufPrintZ(&b, f ++ "\n", a) catch return;
    _ = fputs(s.ptr, stdout);
}

pub export fn koruos_nid_obj_pin(foreign_ptr: [*:0]const u8, key: u64) callconv(.c) u64 {
    const foreign = std.mem.span(foreign_ptr);
    const nid = nidHash(foreign);
    for (objpins[0..n_objpins]) |*p| {
        if (p.nid != nid) continue;
        if (std.mem.eql(u8, p.foreign[0..p.flen], foreign)) {
            if (p.key != key) {
                nidLog("pin refused: foreign={s} nid binds a different key (held={x} asked={x})", .{ foreign, p.key, key });
                return 0;
            }
            return nid; // idempotent: same object, same identity
        }
        nidLog("pin refused: nid collision foreign={s} nid={x}", .{ foreign, nid });
        return 0;
    }
    if (n_objpins == objpins.len or foreign.len > 64) {
        nidLog("pin refused: store full or foreign name too long ({d} chars)", .{foreign.len});
        return 0;
    }
    objpins[n_objpins] = .{ .foreign = undefined, .flen = @intCast(foreign.len), .nid = nid, .key = key };
    @memcpy(objpins[n_objpins].foreign[0..foreign.len], foreign);
    n_objpins += 1;
    nidLog("pin: foreign={s} nid={x} key={x}", .{ foreign, nid, key });
    return nid;
}

pub export fn koruos_nid_obj_key(nid: u64) callconv(.c) i64 {
    for (objpins[0..n_objpins]) |p| {
        if (p.nid == nid) return @bitCast(p.key);
    }
    return -1;
}

// The pin's foreign name back out — exec-by-nid needs the scheme to prove
// the pin belongs to the provider family resolving it ("ext2/d0/12"), not
// just a matching hash. Returns the name length, -1 unbound/short buffer.
pub export fn koruos_nid_obj_foreign(nid: u64, out: [*]u8, cap: usize) callconv(.c) i64 {
    for (objpins[0..n_objpins]) |p| {
        if (p.nid != nid) continue;
        if (p.flen > cap) return -1;
        @memcpy(out[0..p.flen], p.foreign[0..p.flen]);
        return @intCast(p.flen);
    }
    return -1;
}
