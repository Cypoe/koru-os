// koru/native user — ring3 execution + the syscall seam for the spawn
// rung-2 family. The child is a real ELF64 executable: parsed, PT_LOAD
// segments copied into freshly mapped user (U/S) pages in its own CR3
// domain, entered at e_entry via iretq to CPL=3.
//
// The seam is SYSCALL/SYSRET: EFER.SCE set, STAR/LSTAR/SFMASK programmed
// in loadTables. SYSCALL does no stack switch — the entry stub saves the
// user rsp into child_ursp, swaps to the kernel rsp0 stack, pushes the
// full GP frame (rcx=user rip / r11=user rflags ride in the frame),
// and calls ring3_trap. SYSRETQ restores both from the frame.
//
// Rights: child_rights is a per-spawn nr bitmask — the dispatcher
// refuses (-EACCES, loud on serial) any nr not in the bag BEFORE
// dispatch. This is where the spawn lift's bag model becomes
// load-bearing: exec hands the bag down, the seam enforces it.
//
// Honest scope: int 0x80's gate stays installed (same dispatcher — it
// enforces the same bag), exit still resumes the spawn caller rather
// than scheduling, one child at a time. Kernel pages stay ring0-only
// in the child space (U/S clear on identity leaves): the isolation is
// real.

const std = @import("std");

extern var pml4: [512]u64;
extern var pdpt: [512]u64;
extern var pd: [512]u64;

extern var stdout: ?*anyopaque;
extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern fn posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) callconv(.c) c_int;
extern fn serPut(c: u8) callconv(.c) void;

const ENT: u64 = 0x3; // present | writable
const US: u64 = 0x4; // user-accessible

const USER_BASE: usize = 0x800000; // pd[4] -> pt -> user pages (8-10 MiB window)
const USER_STACK_TOP: usize = 0x802000; // second user page, top

fn say(s: [*:0]const u8) void {
    _ = fputs(s, stdout);
}

fn puthex(v: u64) void {
    const digs = "0123456789abcdef";
    var buf: [17]u8 = undefined;
    var i: u6 = 16;
    while (i > 0) {
        i -= 1;
        buf[15 - i] = digs[@intCast((v >> (i * 4)) & 0xF)];
    }
    buf[16] = 0;
    say(@ptrCast(&buf));
}

fn putdec(v0: u64) void {
    var buf: [21]u8 = undefined;
    buf[20] = 0;
    var i: usize = 20;
    var v = v0;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (v != 0) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
        v /= 10;
    }
    say(@ptrCast(&buf[i]));
}

// sibling .zig files (virtio) print through these — the .c-callable
// surface, same as koru_irq_unmask
pub export fn koru_say(s: [*:0]const u8) callconv(.c) void {
    say(s);
}
pub export fn koru_putdec(v: u64) callconv(.c) void {
    putdec(v);
}

// ---- the embedded ELF64 child --------------------------------------------
// write(1, "elf child says hi\n", 18); exit(42) — hand-assembled, laid out as
// one PT_LOAD at file offset 0x78 mapped at vaddr 0x800078.
//
//   B8 01 00 00 00            mov $1, %eax        (write)
//   BF 01 00 00 00            mov $1, %edi        (fd)
//   48 8D 35 15 00 00 00      lea 0x15(%rip),%rsi (msg)
//   BA 12 00 00 00            mov $18, %edx       (len)
//   0F 05                     syscall
//   B8 3C 00 00 00            mov $60, %eax       (exit)
//   BF 2A 00 00 00            mov $42, %edi
//   0F 05                     syscall
//   EB FE                     jmp $               (paranoia)
//   "elf child says hi\n"
const child_code = [_]u8{
    0xB8, 0x01, 0x00, 0x00, 0x00, 0xBF, 0x01, 0x00, 0x00, 0x00,
    0x48, 0x8D, 0x35, 0x15, 0x00, 0x00, 0x00, 0xBA, 0x12, 0x00,
    0x00, 0x00, 0x0F, 0x05, 0xB8, 0x3C, 0x00, 0x00, 0x00, 0xBF,
    0x2A, 0x00, 0x00, 0x00, 0x0F, 0x05, 0xEB, 0xFE,
    'e', 'l', 'f', ' ', 'c', 'h', 'i', 'l', 'd', ' ',
    's', 'a', 'y', 's', ' ', 'h', 'i', '\n',
};

fn u16le(b: []const u8, off: usize) u16 {
    return @as(u16, b[off]) | (@as(u16, b[off + 1]) << 8);
}
fn u32le(b: []const u8, off: usize) u32 {
    return @as(u32, b[off]) | (@as(u32, b[off + 1]) << 8) |
        (@as(u32, b[off + 2]) << 16) | (@as(u32, b[off + 3]) << 24);
}
fn u64le(b: []const u8, off: usize) u64 {
    return @as(u64, u32le(b, off)) | (@as(u64, u32le(b, off + 4)) << 32);
}

fn u32wr(b: []u8, off: usize, v: u32) void {
    b[off] = @intCast(v & 0xFF);
    b[off + 1] = @intCast((v >> 8) & 0xFF);
    b[off + 2] = @intCast((v >> 16) & 0xFF);
    b[off + 3] = @intCast((v >> 24) & 0xFF);
}
fn u64wr(b: []u8, off: usize, v: u64) void {
    u32wr(b, off, @truncate(v));
    u32wr(b, off + 4, @truncate(v >> 32));
}

const EHDR = 64;
const PHDR = 56;
const SEG_OFF: usize = 0x78; // right after ehdr+phdr
const SEG_VADDR: usize = USER_BASE + SEG_OFF;

const child_elf = blk: {
    var b: [EHDR + PHDR + child_code.len]u8 = [_]u8{0} ** (EHDR + PHDR + child_code.len);
    // e_ident
    b[0] = 0x7F; b[1] = 'E'; b[2] = 'L'; b[3] = 'F';
    b[4] = 2; b[5] = 1; b[6] = 1; // 64-bit, LE, ver 1
    u16wr(&b, 16, 2); // ET_EXEC
    u16wr(&b, 18, 0x3E); // EM_X86_64
    u32wr(&b, 20, 1); // version
    u64wr(&b, 24, SEG_VADDR); // e_entry
    u64wr(&b, 32, EHDR); // e_phoff
    u16wr(&b, 52, EHDR); // e_ehsize
    u16wr(&b, 54, PHDR); // e_phentsize
    u16wr(&b, 56, 1); // e_phnum
    // phdr: PT_LOAD, R+X
    u32wr(&b, EHDR + 0, 1);
    u32wr(&b, EHDR + 4, 5);
    u64wr(&b, EHDR + 8, SEG_OFF);
    u64wr(&b, EHDR + 16, SEG_VADDR);
    u64wr(&b, EHDR + 24, SEG_VADDR);
    u64wr(&b, EHDR + 32, child_code.len); // filesz
    u64wr(&b, EHDR + 40, child_code.len); // memsz
    u64wr(&b, EHDR + 48, 1); // align
    @memcpy(b[SEG_OFF .. SEG_OFF + child_code.len], &child_code);
    break :blk b;
};

fn u16wr(b: []u8, off: usize, v: u16) void {
    b[off] = @intCast(v & 0xFF);
    b[off + 1] = @intCast((v >> 8) & 0xFF);
}

// ---- GDT/TSS/IDT ----------------------------------------------------------
// gdt2 mirrors the boot GDT then adds user data/code + a 128-bit TSS
// descriptor patched in at runtime (its base is a runtime address).
var gdt2: [8]u64 align(8) = .{
    0x0000000000000000,
    0x00AF9A000000FFFF, // 0x08 kernel code64
    0x00CF92000000FFFF, // 0x10 kernel data
    0x00CFF2000000FFFF, // 0x18 user data   (DPL=3)
    0x00AFFA000000FFFF, // 0x20 user code64 (DPL=3, L)
    0, 0, 0, // 0x28 TSS descriptor (two quads) + pad
};
var tss: [104]u8 align(16) = [_]u8{0} ** 104;
var idt: [512]u64 align(16) = [_]u64{0} ** 512;
var kstack: [4096]u8 align(16) = [_]u8{0} ** 4096;

fn patchTssDesc() void {
    const base: u64 = @intFromPtr(&tss);
    const limit: u64 = 103;
    gdt2[5] = (limit & 0xFFFF) | ((base & 0xFFFFFF) << 16) |
        (0x89 << 40) | (((base >> 24) & 0xFF) << 56);
    gdt2[6] = base >> 32;
}

fn setIdtGate(idx: usize, handler: usize, dpl3: bool) void {
    const attr: u64 = if (dpl3) 0xEE else 0x8E; // int gate, present, DPL
    const lo: u64 = (handler & 0xFFFF) | (0x08 << 16) | (attr << 40) |
        (((handler >> 16) & 0xFFFF) << 48);
    idt[idx * 2] = lo;
    idt[idx * 2 + 1] = handler >> 32;
}

extern fn ring3_entry80() void;
extern fn ring3_syscall_entry() void;

// ---- interrupts ---------------------------------------------------------
// The real IDT: vectors 0-31 get gates that report and halt (except #BP,
// which resumes — a delivered exception that doesn't kill anything is the
// evidence), 0x20-0x2F are the remapped 8259 PIC lines (timer + the virtio
// device's INTx). SYSCALL/int-0x80 keep their entries. With the table
// populated, stray delivery stops being a triple-fault — so the child can
// run IF=1 again and the kernel takes interrupts anywhere.

fn outb(port: u16, v: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (v),
          [p] "N{dx}" (port),
        : .{ .memory = true });
}
fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "N{dx}" (port),
        : .{ .memory = true });
}

// 8259 remap: master → vectors 0x20-0x27, slave → 0x28-0x2F, all masked.
fn picInit() void {
    outb(0x20, 0x11);
    outb(0xA0, 0x11);
    outb(0x21, 0x20);
    outb(0xA1, 0x28);
    outb(0x21, 0x04);
    outb(0xA1, 0x02);
    outb(0x21, 0x01);
    outb(0xA1, 0x01);
    outb(0x21, 0xFF);
    outb(0xA1, 0xFF);
}
fn picEoi(vec: u64) void {
    if (vec >= 0x28) outb(0xA0, 0x20);
    outb(0x20, 0x20);
}
// Providers call this once they know their line (virtio reads it from PCI
// config). irq is the PIC line (0-15), not the vector.
pub export fn koru_irq_unmask(irq: u8) callconv(.c) void {
    say("irq: unmask line ");
    puthex(irq);
    say("\n");
    const port: u16 = if (irq < 8) 0x21 else 0xA1;
    const bit: u3 = @intCast(irq & 7);
    outb(port, inb(port) & ~(@as(u8, 1) << bit));
    // a slave line only reaches the CPU through master's cascade input 2
    if (irq >= 8) outb(0x21, inb(0x21) & ~@as(u8, 4));
}

pub export var irq_ticks: u64 = 0;
var virtio_seen: u64 = 0;

// virtio.zig exports these once the device is found; 0xFF = unconfigured.
extern var virtio_irq_line: u8;
extern fn virtio_irq_ack() void;

const ExcFrame = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    vec: u64,
    err: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    // ss/usp trail when the source was CPL=3 — hardware layout, unread.
};

export fn irq_exc_dispatch(f: *ExcFrame) callconv(.c) void {
    if (f.vec >= 0x20 and f.vec < 0x30) {
        if (f.vec == 0x20) {
            irq_ticks += 1;
            if (irq_ticks == 1) say("irq: timer delivered\n");
        } else if (virtio_irq_line != 0xFF and f.vec == 0x20 + @as(u64, virtio_irq_line)) {
            virtio_irq_ack();
            virtio_seen += 1;
            if (virtio_seen == 1) say("irq: virtio delivered\n");
        } else {
            // unclaimed line: report once, then mask it at the PIC so a
            // level-asserted storm can't drown the boot (PS/2 aux fires
            // IRQ12 on QEMU despite the IMR — masking stops delivery)
            say("irq: stray vec=");
            puthex(f.vec);
            say(" (masked)\n");
            const l: u8 = @intCast(f.vec - 0x20);
            const port: u16 = if (l < 8) 0x21 else 0xA1;
            const bit: u3 = @intCast(l & 7);
            outb(port, inb(port) | (@as(u8, 1) << bit));
        }
        picEoi(f.vec);
        return;
    }
    say("EXC v=");
    puthex(f.vec);
    say(" rip=");
    puthex(f.rip);
    say(" err=");
    puthex(f.err);
    if (f.vec == 3) {
        say(" (continued)\n");
        return;
    }
    say(" — halting\n");
    while (true) asm volatile ("cli; hlt");
}

// Stub table: vectors 0-31 are exceptions (8,10-14,17,21,29,30 carry a
// hardware error code — for those the stub pushes only the vector; the
// rest push a dummy err first), 0x20-0x2F are IRQ lines. All land on one
// common entry. The rsp parity at stub entry is NOT fixed (CPL0 vs CPL3
// sources push different frame sizes), so the common entry force-aligns
// with AND before calling into Zig — a fixed sub would be wrong half the
// time (the lesson of three movaps GPFs).
comptime {
    var src: []const u8 = ".section .text\n";
    const errv = [_]u8{ 8, 10, 11, 12, 13, 14, 17, 21, 29, 30 };
    for (0..48) |v| {
        var has_err = false;
        for (errv) |e| has_err = has_err or e == v;
        src = src ++ std.fmt.comptimePrint("irqstub_{d}:\n", .{v});
        if (!has_err) src = src ++ "  push $0\n";
        src = src ++ std.fmt.comptimePrint("  push ${d}\n  jmp irq_exc_common\n", .{v});
    }
    // a link-time address table — stub encodings stay free to vary
    src = src ++ ".section .rodata\n.globl irqstub_table\n.align 8\nirqstub_table:\n";
    for (0..48) |v| src = src ++ std.fmt.comptimePrint("  .quad irqstub_{d}\n", .{v});
    src = src ++ ".section .text\n";
    src = src ++
        \\ irq_exc_common:
        \\   push %r15
        \\   push %r14
        \\   push %r13
        \\   push %r12
        \\   push %r11
        \\   push %r10
        \\   push %r9
        \\   push %r8
        \\   push %rbp
        \\   push %rdi
        \\   push %rsi
        \\   push %rdx
        \\   push %rcx
        \\   push %rbx
        \\   push %rax
        \\   mov %rsp, %rdi
        \\   mov %rsp, %rbx
        \\   and $-16, %rsp
        \\   call irq_exc_dispatch
        \\   mov %rbx, %rsp
        \\   pop %rax
        \\   pop %rbx
        \\   pop %rcx
        \\   pop %rdx
        \\   pop %rsi
        \\   pop %rdi
        \\   pop %rbp
        \\   pop %r8
        \\   pop %r9
        \\   pop %r10
        \\   pop %r11
        \\   pop %r12
        \\   pop %r13
        \\   pop %r14
        \\   pop %r15
        \\   add $16, %rsp
        \\   iretq
        \\
    ;
    asm (src);
}

extern var irqstub_table: [48]u64;

// Called once from kmain, before the program runs: PIC remapped, every
// gate populated, interrupts on.
pub fn init() void {
    picInit();
    // v3 must be DPL=3 — #BP is raised by int3 from user code and the
    // DPL check applies
    for (0..48) |v| setIdtGate(v, irqstub_table[v], v == 3);
    loadTables();
    koru_irq_unmask(0); // PIT tick — the standing delivery proof
    asm volatile ("sti");
}

// Per-child state the seam reads at ring transition. One child at a time
// (spawn blocks), so plain globals are honest.
pub export var child_ursp: u64 = 0; // user rsp saved across the syscall
pub export var rsp0_val: u64 = 0; // kernel stack top for the syscall entry
pub export var child_rights: u64 = 0; // nr bitmask — the bag, enforced

// Program the SYSCALL MSRs. STAR: syscall base 0x08 (CS=0x08, SS=0x10),
// sysret base 0x10 (SS=0x18|3=0x1B user data, CS=0x20|3=0x23 user code —
// the gdt2 layout happens to match the required +8/+16 ordering).
fn enableSyscall() void {
    rsp0_val = @intFromPtr(&kstack) + kstack.len;
    asm volatile (
        \\ mov $0xC0000080, %ecx
        \\ rdmsr
        \\ or $1, %eax
        \\ wrmsr
        \\ mov $0xC0000081, %ecx
        \\ movl $0x00100008, %edx
        \\ xor %eax, %eax
        \\ wrmsr
        \\ mov $0xC0000082, %ecx
        \\ mov %[lstar], %rdx
        \\ mov %edx, %eax
        \\ shr $32, %rdx
        \\ wrmsr
        \\ mov $0xC0000084, %ecx
        \\ mov $0x200, %eax
        \\ xor %edx, %edx
        \\ wrmsr
        :
        : [lstar] "r" (@intFromPtr(&ring3_syscall_entry)),
        : .{ .memory = true, .rax = true, .rcx = true, .rdx = true });
}

fn loadTables() void {
    patchTssDesc();
    var gdt_ptr: [10]u8 align(2) = undefined;
    gdt_ptr[0] = 8 * 8 - 1;
    gdt_ptr[1] = 0;
    const gbase: u64 = @intFromPtr(&gdt2);
    inline for (0..8) |i| gdt_ptr[2 + i] = @intCast((gbase >> (8 * i)) & 0xFF);
    asm volatile ("lgdt (%[p])"
        :
        : [p] "r" (&gdt_ptr),
        : .{ .memory = true });
    asm volatile (
        \\ movw $0x10, %ax
        \\ movw %ax, %ds
        \\ movw %ax, %es
        \\ movw %ax, %ss
        \\ movw $0x28, %ax
        \\ ltr %ax
        ::: .{ .memory = true });
    const rsp0: u64 = @intFromPtr(&kstack) + kstack.len;
    @as(*u64, @ptrCast(@alignCast(&tss[4]))).* = rsp0;

    var idt_ptr: [10]u8 align(2) = undefined;
    idt_ptr[0] = 0xFF;
    idt_ptr[1] = 0xFF;
    const ibase: u64 = @intFromPtr(&idt);
    inline for (0..8) |i| idt_ptr[2 + i] = @intCast((ibase >> (8 * i)) & 0xFF);
    setIdtGate(0x80, @intFromPtr(&ring3_entry80), true);
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&idt_ptr),
        : .{ .memory = true });
    enableSyscall();
}

// ---- child space -----------------------------------------------------------

var c_pml4: *align(4096) [512]u64 = undefined;
var c_pdpt: *align(4096) [512]u64 = undefined;
var c_pd: *align(4096) [512]u64 = undefined;
var c_pt: *align(4096) [512]u64 = undefined;
var stack_page: *align(4096) [4096]u8 = undefined;

fn allocPage() ?*align(4096) [4096]u8 {
    var p: ?*anyopaque = null;
    if (posix_memalign(&p, 4096, 4096) != 0 or p == null) return null;
    const t: *align(4096) [4096]u8 = @ptrCast(@alignCast(p.?));
    @memset(t, 0);
    return t;
}

// Map one 4 KiB user page for `vaddr` inside the pd[4] window.
fn mapUserPage(vaddr: usize) ?*align(4096) [4096]u8 {
    if (vaddr < USER_BASE or vaddr >= USER_BASE + 0x200000) return null;
    const idx = (vaddr >> 12) & 0x1FF;
    const page = allocPage() orelse return null;
    c_pt[idx] = @intFromPtr(page) | US | ENT;
    return page;
}

fn buildTables() bool {
    c_pml4 = @ptrCast(@alignCast(allocPage() orelse return false));
    c_pdpt = @ptrCast(@alignCast(allocPage() orelse return false));
    c_pd = @ptrCast(@alignCast(allocPage() orelse return false));
    c_pt = @ptrCast(@alignCast(allocPage() orelse return false));
    // U/S must hold at every level for ring3 to reach a leaf; kernel leaves
    // in the copied pd still lack the bit, so the kernel half stays
    // ring0-only.
    c_pml4[0] = @intFromPtr(c_pdpt) | US | ENT;
    c_pdpt[0] = @intFromPtr(c_pd) | US | ENT;
    c_pd.* = pd;
    c_pd[4] = @intFromPtr(c_pt) | US | ENT;
    stack_page = allocPage() orelse return false;
    c_pt[1] = @intFromPtr(stack_page) | US | ENT;
    return true;
}

// Parse an ELF64 image, map PT_LOAD pages, return e_entry.
fn loadElf(b: []const u8) ?usize {
    if (b.len < EHDR or b[0] != 0x7F or b[1] != 'E' or b[2] != 'L' or
        b[3] != 'F' or b[4] != 2 or b[5] != 1) return null;
    if (u16le(b, 16) != 2 or u16le(b, 18) != 0x3E) return null;
    const entry = u64le(b, 24);
    const phoff: usize = @intCast(u64le(b, 32));
    const phentsz: usize = u16le(b, 54);
    const phnum: usize = u16le(b, 56);
    if (phnum == 0 or phentsz < PHDR or phoff + phnum * phentsz > b.len)
        return null;
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const ph = phoff + i * phentsz;
        if (u32le(b, ph) != 1) continue; // PT_LOAD only
        const off: usize = @intCast(u64le(b, ph + 8));
        const vaddr: usize = @intCast(u64le(b, ph + 16));
        const filesz: usize = @intCast(u64le(b, ph + 32));
        const memsz: usize = @intCast(u64le(b, ph + 40));
        if (filesz > memsz or off + filesz > b.len) return null;
        var p = vaddr & ~@as(usize, 0xFFF);
        while (p < vaddr + memsz) : (p += 0x1000) {
            _ = mapUserPage(p) orelse return null;
        }
        // copy through the mapped page via identity VA
        var n: usize = 0;
        while (n < filesz) : (n += 1) {
            const va = vaddr + n;
            const phys = c_pt[(va >> 12) & 0x1FF] & ~@as(u64, 0xFFF);
            const dst: [*]u8 = @ptrFromInt(@as(usize, @intCast(phys)) + (va & 0xFFF));
            dst[0] = b[off + n];
        }
    }
    return @intCast(entry);
}

// ---- the seam ---------------------------------------------------------------
// Frame pushed by ring3_entry80 before calling ring3_trap: offsets match the
// push order (rax last, top of frame).
const TrapFrame = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
};

// ---- spawn primitive ------------------------------------------------------
// koru_spawn_elf is the native-runtime provider for koruos/spawn:exec — the
// rung-2 spawn family: the image is a caller-supplied ELF64 (ext2-loaded for
// the disk case, embedded for the no-disk case), spawned in its own CR3 at
// CPL=3, and its exit() RESUMES the caller: the asm below saves callee regs
// and a resume address (1:) before iretq; the exit path in ring3_trap
// restores kernel CR3+rsp and jmps straight into that resume label. The
// function is a normal call from the program's perspective — spawn blocks
// until the child exits, returns its status.
pub export var saved_rsp: u64 = 0;
pub export var saved_rip: u64 = 0;
pub export var last_exit: u64 = 0;

export fn ring3_trap(f: *TrapFrame) callconv(.c) void {
    // bag check before dispatch: an nr not granted in child_rights is a
    // capability refusal, loud on serial AND visible to the child as
    // -EACCES — not a silent ENOSYS.
    if (f.rax >= 64 or (child_rights >> @as(u6, @intCast(f.rax))) & 1 == 0) {
        say("SEAM REFUSE nr=");
        puthex(f.rax);
        say(" (not in child bag)\n");
        f.rax = @bitCast(@as(i64, -13));
        return;
    }
    switch (f.rax) {
        1 => { // write(fd, buf, len) -> len
            const buf: [*]const u8 = @ptrFromInt(@as(usize, @intCast(f.rsi)));
            var i: usize = 0;
            while (i < f.rdx) : (i += 1) serPut(buf[i]);
            f.rax = f.rdx;
        },
        2 => { // getpid — defined so "granted vs refused" is decidable
            f.rax = 1;
        },
        60 => { // exit(code) — resume the caller's spawn path, don't halt
            last_exit = f.rdi;
            asm volatile (
                \\ mov %[cr3], %%rax
                \\ mov %%rax, %%cr3
                \\ mov saved_rsp(%%rip), %%rsp
                \\ jmp *saved_rip(%%rip)
                :
                : [cr3] "r" (@intFromPtr(&pml4)),
                : .{ .memory = true });
            unreachable;
        },
        else => f.rax = @bitCast(@as(i64, -38)), // ENOSYS
    }
}

comptime {
    asm (
        \\ .section .text
        \\ .globl ring3_entry80
        \\ ring3_entry80:
        \\   push %r15
        \\   push %r14
        \\   push %r13
        \\   push %r12
        \\   push %r11
        \\   push %r10
        \\   push %r9
        \\   push %r8
        \\   push %rbp
        \\   push %rdi
        \\   push %rsi
        \\   push %rdx
        \\   push %rcx
        \\   push %rbx
        \\   push %rax
        \\   mov %rsp, %rdi
        \\   call ring3_trap
        \\   pop %rax
        \\   pop %rbx
        \\   pop %rcx
        \\   pop %rdx
        \\   pop %rsi
        \\   pop %rdi
        \\   pop %rbp
        \\   pop %r8
        \\   pop %r9
        \\   pop %r10
        \\   pop %r11
        \\   pop %r12
        \\   pop %r13
        \\   pop %r14
        \\   pop %r15
        \\   iretq
    );
}

// SYSCALL entry: the CPU lands here (LSTAR) with rcx=user rip,
// r11=user rflags, and THE USER STACK STILL LIVE — unlike int, no TSS
// switch happens. Swap to the kernel rsp0 stack, save the GP frame in
// the same TrapFrame order, call the dispatcher, then sysretq (rcx/r11
// ride back out of the frame). SFMASK already cleared IF.
comptime {
    asm (
        \\ .section .text
        \\ .globl ring3_syscall_entry
        \\ ring3_syscall_entry:
        \\   mov %rsp, child_ursp(%rip)
        \\   mov rsp0_val(%rip), %rsp
        \\   push %r15
        \\   push %r14
        \\   push %r13
        \\   push %r12
        \\   push %r11
        \\   push %r10
        \\   push %r9
        \\   push %r8
        \\   push %rbp
        \\   push %rdi
        \\   push %rsi
        \\   push %rdx
        \\   push %rcx
        \\   push %rbx
        \\   push %rax
        // int's 40-byte hardware frame happened to land the callee
        // 16-aligned; this manual path pushes 15 regs — pad 8 so
        // ring3_trap's call site is call-conformant (movaps GPFs else).
        // rdi takes the frame BEFORE the pad.
        \\   mov %rsp, %rdi
        \\   sub $8, %rsp
        \\   call ring3_trap
        \\   add $8, %rsp
        \\   pop %rax
        \\   pop %rbx
        \\   pop %rcx
        \\   pop %rdx
        \\   pop %rsi
        \\   pop %rdi
        \\   pop %rbp
        \\   pop %r8
        \\   pop %r9
        \\   pop %r10
        \\   pop %r11
        \\   pop %r12
        \\   pop %r13
        \\   pop %r14
        \\   pop %r15
        \\   mov child_ursp(%rip), %rsp
        \\   sysretq
    );
}

// Spawn a caller-supplied ELF64 image in a fresh child space. Blocks until
// the child exits through the seam; returns its exit code (< 0 on setup
// refusal: -1 tables, -2 image).
pub export fn koru_spawn_elf(image: [*]const u8, size: usize, rights: u64) callconv(.c) c_int {
    child_rights = rights;
    if (!buildTables()) {
        say("RING3 FAIL: page alloc\n");
        return -1;
    }
    const entry = loadElf(image[0..size]) orelse {
        say("ELF LOAD FAIL\n");
        return -2;
    };
    loadTables();
    asm volatile (
        \\ push %rbx
        \\ push %rbp
        \\ push %r12
        \\ push %r13
        \\ push %r14
        \\ push %r15
        \\ mov %%rsp, saved_rsp(%%rip)
        // consume %[cr3] before any scratch use — the lea below is free to
        // take rax only after the input has been moved into CR3
        \\ mov %[cr3], %%rax
        \\ mov %%rax, %%cr3
        \\ lea 1f(%%rip), %%rax
        \\ mov %%rax, saved_rip(%%rip)
        \\ push $0x1B
        \\ push %[stk]
        // IF=1: the IDT is fully populated now — IRQs land on real gates,
        // the child may be interrupted and resumed
        \\ push $0x202
        \\ push $0x23
        \\ push %[rip]
        \\ iretq
        \\ 1:
        \\ pop %r15
        \\ pop %r14
        \\ pop %r13
        \\ pop %r12
        \\ pop %rbp
        \\ pop %rbx
        :
        : [cr3] "r" (@intFromPtr(c_pml4)),
          [stk] "r" (@as(usize, USER_STACK_TOP)),
          [rip] "r" (entry),
        : .{ .memory = true });
    return @intCast(last_exit);
}

// No-disk evidence path: spawn the embedded child once.
pub fn run() void {
    const st = koru_spawn_elf(&child_elf, child_elf.len, (1 << 1) | (1 << 60));
    say("EMBED SPAWN exit=");
    puthex(@intCast(@as(u32, @bitCast(st))));
    say("\n");
}
