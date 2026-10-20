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

const COM1: u16 = 0x3F8;

fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
        : .{ .memory = true }
    );
}

fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
        : .{ .memory = true }
    );
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

fn serPut(c: u8) void {
    while (inb(COM1 + 5) & 0x20 == 0) {} // wait for empty THR
    outb(COM1, c);
}

// ---- console contract -----------------------------------------------------

// fd-like tokens so a future multi-sink provider can distinguish the streams.
pub export var stdout: ?*anyopaque = @ptrFromInt(1);
pub export var stderr: ?*anyopaque = @ptrFromInt(2);

export fn fputs(s: [*:0]const u8, stream: ?*anyopaque) callconv(.c) c_int {
    _ = stream;
    serInit();
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {
        if (s[n] == '\n') serPut('\r');
        serPut(s[n]);
    }
    return @intCast(n);
}

// ---- heap contract --------------------------------------------------------

const HEAP_SIZE = 4 * 1024 * 1024;
var heap: [HEAP_SIZE]u8 align(4096) = undefined;
var heap_off: usize = 0;

export fn posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) callconv(.c) c_int {
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

export fn free(ptr: ?*anyopaque) callconv(.c) void {
    _ = ptr;
}
