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
const pmm = @import("pmm");
const kbd = @import("kbd");
extern fn serPut(c: u8) callconv(.c) void;

const ENT: u64 = 0x3; // present | writable
const US: u64 = 0x4; // user-accessible

// Child user space is its own pdpt slot — [USER_VA_BASE, USER_VA_END)
// maps through c.upd, kept entirely clear of the kernel-half pd copy
// (identity RAM) the ISR still needs on the child's CR3. Real ET_EXEC
// vaddrs below 0x40000000 therefore refuse by name: the honest answer
// is static-pie (ET_DYN) or a link above the identity region.
const USER_VA_BASE: usize = 0x4000_0000; // pdpt[1] -> upd -> user pages
const USER_VA_END: usize = 0x7FE0_0000;  // ~1 GiB of user space
const USER_STACK_TOP: usize = 0x7FE0_0000; // stack pages map just below
const USER_STACK_PAGES: usize = 16;
const MMAP_BASE: usize = 0x6000_0000; // mmap arena — between image and stack

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
// one PT_LOAD at file offset 0x78 mapped at vaddr USER_VA_BASE+0x78.
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
const SEG_VADDR: usize = USER_VA_BASE + SEG_OFF;

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

// Tick preemption, in place: if the interrupted context was CPL3 and the
// epoch is live, the on-stack frame IS the outgoing child's context — copy
// it into its slot, copy the next runnable child's saved frame over the
// stack image, flip CR3 to its space, and let irq_exc_common's tail resume
// it. cs&3 != 3 means the tick interrupted CPL0 work (ISR, syscall, kmain)
// — there is no user frame on the stack to steal, so nothing rotates.
fn schedPreempt(f: *ExcFrame) void {
    if (!sched_active or nchildren == 0) return;
    if (f.cs & 3 != 3) return;
    const st: [*]const u64 = @ptrCast(f);
    const c = &children[cur_child];
    for (0..15) |i| c.frame.gp[i] = st[i];
    c.frame.rip = st[17];
    c.frame.cs = st[18];
    c.frame.rflags = st[19];
    c.frame.rsp = st[20];
    c.frame.ss = st[21];
    var nxt = cur_child;
    for (0..nchildren) |k| {
        const j = (cur_child + 1 + k) % nchildren;
        if (children[j].state == .runnable) {
            nxt = j;
            break;
        }
    }
    if (nxt == cur_child) return;
    const nx = &children[nxt];
    cur_child = nxt;
    child_rights = nx.rights;
    const out: [*]u64 = @ptrCast(f);
    for (0..15) |i| out[i] = nx.frame.gp[i];
    out[17] = nx.frame.rip;
    out[18] = nx.frame.cs;
    out[19] = nx.frame.rflags;
    out[20] = nx.frame.rsp;
    out[21] = nx.frame.ss;
    asm volatile ("mov %[c], %%cr3"
        :
        : [c] "r" (nx.pml4),
        : .{ .memory = true });
    sched_switches += 1;
}

export fn irq_exc_dispatch(f: *ExcFrame) callconv(.c) void {
    if (f.vec >= 0x20 and f.vec < 0x30) {
        if (f.vec == 0x20) {
            irq_ticks += 1;
            if (irq_ticks == 1) say("irq: timer delivered\n");
            schedPreempt(f);
        } else if (f.vec == 0x21) {
            kbd.irq(); // 8042 scancode → input ring
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
// Per-child state — one 4-level chain (pml4→pdpt→pd→pt) + a resumable user
// frame per child. A frame is the whole user context: the 15 GP regs in
// trap-frame order plus the iret tail (rip/cs/rflags/rsp/ss) — the same
// layout the irq stub stack carries, so a preempted child's frame can be
// written back onto a live interrupt frame in place and the common pop +
// iretq tail resumes it.

const UserFrame = extern struct {
    gp: [15]u64, // rax..r15 in on-stack order (rax lowest)
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

const ChildState = enum { empty, runnable, dead };
const MAXCHILDREN: usize = 4;

const Child = struct {
    pml4: usize = 0,
    pdpt: usize = 0,
    pd: usize = 0,   // kernel-half copy (identity RAM, ISR on child CR3)
    upd: usize = 0,  // user-half pd — pdpt[1], USER_VA_BASE..END
    fsbase: u64 = 0, // TLS base (arch_prctl) — MSR-loaded at resume
    brk: usize = 0,  // program break (brk syscall)
    brk_base: usize = 0, // lowest legal break — end of the loaded image
    mmap_top: usize = 0, // bump cursor of the mmap arena
    frame: UserFrame = std.mem.zeroes(UserFrame),
    rights: u64 = 0,
    state: ChildState = .empty,
};

var children: [MAXCHILDREN]Child = .{ .{}, .{}, .{}, .{} };
var nchildren: usize = 0;
var cur_child: usize = 0;
var sched_active = false;
pub export var sched_switches: u64 = 0;

// Child memory comes from the frame allocator, not the bump heap: every
// table and user page is a refcounted frame that freeChild returns on
// exit — reclaim is the point of the rung, not a later nicety.
fn allocPage() ?*align(4096) [4096]u8 {
    const phys = pmm.alloc() orelse return null;
    const t: *align(4096) [4096]u8 = @ptrFromInt(@as(usize, @intCast(phys)));
    @memset(t, 0);
    return t;
}

// Return every frame a dead child held: every pt under its user pd and
// every page those pts map, then the four table pages themselves. Runs
// on the dead child's stack — the frame frees only release the refcount,
// the identity map keeps the pages readable until we jump away, and
// nothing allocates in between.
fn freeChild(c: *Child) usize {
    var freed: usize = 0;
    if (c.upd == 0) return 0;
    const c_upd: *const [512]u64 = @ptrFromInt(@as(usize, @intCast(c.upd)));
    for (c_upd) |pde| {
        if (pde & 1 == 0) continue;
        const pt: *const [512]u64 = @ptrFromInt(@as(usize, @intCast(pde & ~@as(u64, 0xFFF))));
        for (pt) |e| {
            if (e & 1 != 0) {
                _ = pmm.free(e & ~@as(u64, 0xFFF));
                freed += 1;
            }
        }
        _ = pmm.free(pde & ~@as(u64, 0xFFF));
        freed += 1;
    }
    for ([_]u64{ c.upd, c.pd, c.pdpt, c.pml4 }) |t| {
        if (t != 0) {
            _ = pmm.free(t);
            freed += 1;
        }
    }
    c.upd = 0;
    c.pd = 0;
    c.pdpt = 0;
    c.pml4 = 0;
    return freed;
}

// Map one 4 KiB user page for `vaddr` inside `c`'s user window, growing
// the upd's pt on demand. Returns the frame (identity VA) for writes.
fn mapUserPage(c: *Child, vaddr: usize) ?*align(4096) [4096]u8 {
    if (vaddr < USER_VA_BASE or vaddr >= USER_VA_END) return null;
    const upd: *[512]u64 = @ptrFromInt(c.upd);
    const pd_i = (vaddr - USER_VA_BASE) >> 21;
    if (upd[pd_i] & 1 == 0) {
        const npt = allocPage() orelse return null;
        upd[pd_i] = @intFromPtr(npt) | US | ENT;
    }
    const pt: *[512]u64 = @ptrFromInt(@as(usize, @intCast(upd[pd_i] & ~@as(u64, 0xFFF))));
    const idx = (vaddr >> 12) & 0x1FF;
    const page = allocPage() orelse return null;
    pt[idx] = @intFromPtr(page) | US | ENT;
    return page;
}

// raw pte value for a mapped user va (0 if unmapped)
fn userEntry(c: *Child, vaddr: usize) u64 {
    if (vaddr < USER_VA_BASE or vaddr >= USER_VA_END) return 0;
    const upd: *const [512]u64 = @ptrFromInt(c.upd);
    const pd_i = (vaddr - USER_VA_BASE) >> 21;
    if (upd[pd_i] & 1 == 0) return 0;
    const pt: *const [512]u64 = @ptrFromInt(@as(usize, @intCast(upd[pd_i] & ~@as(u64, 0xFFF))));
    return pt[(vaddr >> 12) & 0x1FF];
}

// set/clear the writable bit on mapped user pages (PROT_WRITE down)
fn setUserWritable(c: *Child, vaddr: usize, len: usize, w: bool) void {
    var p = vaddr & ~@as(usize, 0xFFF);
    const end = vaddr + len;
    while (p < end) : (p += 0x1000) {
        const upd: *[512]u64 = @ptrFromInt(c.upd);
        const pd_i = (p - USER_VA_BASE) >> 21;
        if (upd[pd_i] & 1 == 0) continue;
        const pt: *[512]u64 = @ptrFromInt(@as(usize, @intCast(upd[pd_i] & ~@as(u64, 0xFFF))));
        const idx = (p >> 12) & 0x1FF;
        if (pt[idx] & 1 == 0) continue;
        if (w) pt[idx] |= 2 else pt[idx] &= ~@as(u64, 2);
    }
}

// phys of an already-mapped user page in `c`'s space (loader writes
// through the kernel identity map).
fn userPhys(c: *Child, vaddr: usize) usize {
    const upd: *const [512]u64 = @ptrFromInt(c.upd);
    const pd_i = (vaddr - USER_VA_BASE) >> 21;
    const pt: *const [512]u64 = @ptrFromInt(@as(usize, @intCast(upd[pd_i] & ~@as(u64, 0xFFF))));
    return @intCast(pt[(vaddr >> 12) & 0x1FF] & ~@as(u64, 0xFFF));
}

fn buildTables(c: *Child) bool {
    c.pml4 = @intFromPtr(allocPage() orelse return false);
    c.pdpt = @intFromPtr(allocPage() orelse return false);
    c.pd = @intFromPtr(allocPage() orelse return false);
    c.upd = @intFromPtr(allocPage() orelse return false);
    const c_pml4: *[512]u64 = @ptrFromInt(c.pml4);
    const c_pdpt: *[512]u64 = @ptrFromInt(c.pdpt);
    const c_pd: *[512]u64 = @ptrFromInt(c.pd);
    // U/S must hold at every level for ring3 to reach a leaf; kernel leaves
    // in the copied pd still lack the bit, so the kernel half stays
    // ring0-only — and identical across children, which is what lets the
    // ISR flip CR3 mid-dispatch without losing itself.
    c_pml4[0] = c.pdpt | US | ENT;
    c_pdpt[0] = c.pd | US | ENT;
    c_pd.* = pd;
    c_pdpt[1] = c.upd | US | ENT;
    return true;
}

const ElfInfo = struct {
    entry: usize,
    phdr_va: usize,
    phent: usize,
    phnum: usize,
    bias: usize,
    brk_base: usize, // page-aligned end of the loaded image
};

// Parse an ELF64 image into `c`'s space: ET_EXEC maps at p_vaddr (must be
// inside the user window — a 0x400000-style link address collides with
// the kernel identity and refuses by name), ET_DYN maps at
// USER_VA_BASE + p_vaddr (the static-pie/libc path — bias application is
// the same mechanism a PT_INTERP ld.so will need). Pages are zeroed at
// alloc, so bss (memsz > filesz) needs no fill. PT_INTERP is not yet
// served: it is refused by name rather than silently ignored.
fn loadElf(c: *Child, b: []const u8) ?ElfInfo {
    if (b.len < EHDR or b[0] != 0x7F or b[1] != 'E' or b[2] != 'L' or
        b[3] != 'F' or b[4] != 2 or b[5] != 1) return null;
    const etype = u16le(b, 16);
    if (u16le(b, 18) != 0x3E or (etype != 2 and etype != 3)) return null;
    const bias: usize = if (etype == 3) USER_VA_BASE else 0;
    const entry = u64le(b, 24);
    const phoff: usize = @intCast(u64le(b, 32));
    const phentsz: usize = u16le(b, 54);
    const phnum: usize = u16le(b, 56);
    if (phnum == 0 or phentsz < PHDR or phoff + phnum * phentsz > b.len)
        return null;
    var phdr_va: usize = 0;
    var max_va: usize = 0;
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const ph = phoff + i * phentsz;
        const ptype = u32le(b, ph);
        if (ptype == 3) { // PT_INTERP — dynamic images are a later rung
            say("ELF REFUSE: PT_INTERP (dynamic) not served yet\n");
            return null;
        }
        if (ptype != 1) continue; // PT_LOAD only
        const off: usize = @intCast(u64le(b, ph + 8));
        const vaddr: usize = @intCast(u64le(b, ph + 16));
        const filesz: usize = @intCast(u64le(b, ph + 32));
        const memsz: usize = @intCast(u64le(b, ph + 40));
        if (filesz > memsz or off + filesz > b.len) return null;
        const va = bias + vaddr;
        const end_va = va + memsz;
        if (end_va > max_va) max_va = end_va;
        if (va < USER_VA_BASE) {
            say("ELF REFUSE: vaddr below user window — link -pie or above 0x40000000\n");
            return null;
        }
        var p = va & ~@as(usize, 0xFFF);
        while (p < va + memsz) : (p += 0x1000) {
            _ = mapUserPage(c, p) orelse return null;
        }
        // copy through the mapped pages via identity VA
        var n: usize = 0;
        while (n < filesz) : (n += 1) {
            const phys = userPhys(c, va + n);
            const dst: [*]u8 = @ptrFromInt(phys + ((va + n) & 0xFFF));
            dst[0] = b[off + n];
        }
        // phdrs are usually inside the first PT_LOAD; remember where they
        // landed so AT_PHDR can point at the in-memory copy.
        if (phoff >= off and phoff + phnum * phentsz <= off + filesz)
            phdr_va = va + (phoff - off);
    }
    if (phdr_va == 0) {
        // phdrs not inside any PT_LOAD — park a copy on its own page.
        const pa = mapUserPage(c, USER_VA_BASE + 0x200000 - 0x1000) orelse return null;
        _ = pa;
        const dst: [*]u8 = @ptrFromInt(userPhys(c, USER_VA_BASE + 0x200000 - 0x1000));
        var n: usize = 0;
        while (n < phnum * phentsz) : (n += 1) dst[n] = b[phoff + n];
        phdr_va = USER_VA_BASE + 0x200000 - 0x1000;
    }
    return .{ .entry = @intCast(bias + entry), .phdr_va = phdr_va, .phent = phentsz, .phnum = phnum, .bias = bias, .brk_base = (max_va + 0xFFF) & ~@as(usize, 0xFFF) };
}

// ---- the real initial process stack ---------------------------------------
// rsp convention a real ELF entry expects: [argc][argv0..][NULL][envp..]
// [NULL][auxv pairs][AT_NULL] — any real libc's _start reads auxv off the
// stack; without this a musl/glibc binary cannot even reach its main.
// Stack pages live at the top of the user window; strings/auxv data are
// written above the vector through the identity map.
fn userWrite(c: *Child, va: usize, v: u64) void {
    const phys = userPhys(c, va);
    const dst: *u64 = @ptrFromInt(phys + (va & 0xFFF));
    dst.* = v;
}

fn buildStack(c: *Child, info: ElfInfo) ?usize {
    var i: usize = 0;
    const sbase = USER_STACK_TOP - USER_STACK_PAGES * 0x1000;
    while (i < USER_STACK_PAGES) : (i += 1) {
        _ = mapUserPage(c, sbase + i * 0x1000) orelse return null;
    }
    // strings + AT_RANDOM block live at the very top
    const arg0 = "child.elf";
    var top = USER_STACK_TOP;
    var n: usize = 0;
    while (n <= arg0.len) : (n += 1) { // include the NUL
        const phys = userPhys(c, top - arg0.len - 1 + n);
        const dst: *u8 = @ptrFromInt(phys + ((top - arg0.len - 1 + n) & 0xFFF));
        dst.* = arg0[n];
    }
    top -= arg0.len + 1;
    const arg0_va = top;
    top -= 16;
    const rand_va = top;
    // AT_RANDOM: 16 bytes, TSC-seeded xorshift — an honest non-crypto seed.
    var s: u64 = rdtsc();
    n = 0;
    while (n < 16) : (n += 1) {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17;
        const phys = userPhys(c, rand_va + n);
        const dst: *u8 = @ptrFromInt(phys + ((rand_va + n) & 0xFFF));
        dst.* = @truncate(s);
    }
    // the vector: argc, argv, NULL, envp NULL, auxv pairs, AT_NULL
    const auxv = [_][2]u64{
        .{ 3, info.phdr_va },  // AT_PHDR
        .{ 4, info.phent },   // AT_PHENT
        .{ 5, info.phnum },   // AT_PHNUM
        .{ 6, 4096 },         // AT_PAGESZ
        .{ 9, info.entry },   // AT_ENTRY
        .{ 11, 0 },           // AT_UID
        .{ 12, 0 },           // AT_GID
        .{ 13, 0 },           // AT_EUID
        .{ 14, 0 },           // AT_EGID
        .{ 16, 0 },           // AT_HWCAP — none advertised
        .{ 17, 100 },         // AT_CLKTCK
        .{ 23, 0 },           // AT_SECURE
        .{ 25, rand_va },     // AT_RANDOM
        .{ 0, 0 },            // AT_NULL
    };
    const vec_slots = 1 + 1 + 1 + 1 + auxv.len * 2; // argc argv0 NUL envpNUL pairs
    const sp = (top - vec_slots * 8) & ~@as(usize, 0xF);
    var at = sp;
    userWrite(c, at, 1); at += 8;          // argc
    userWrite(c, at, arg0_va); at += 8;    // argv[0]
    userWrite(c, at, 0); at += 8;          // argv NULL
    userWrite(c, at, 0); at += 8;          // envp NULL
    for (auxv) |pair| {
        userWrite(c, at, pair[0]); at += 8;
        userWrite(c, at, pair[1]); at += 8;
    }
    return sp;
}

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo), [hi] "={edx}" (hi));
    return (@as(u64, hi) << 32) | lo;
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

// Canonical capability number for a syscall nr. Bits 0..63 name
// capabilities; for NRs <64 the bit IS the Linux nr, so a bag reads
// like a syscall mask. NRs ≥64 have no bit — they fold onto reserved
// caps: 62 = "describe/modify own process metadata" (arch_prctl FS,
// set_tid_address, set_robust_list, prlimit64), 61 = "entropy"
// (getrandom), and 231 -> 60 (exit_group IS exit for single-threaded
// children). The grant-object bag replacing this bitmask is the
// standing axis (concepts/frag-bag-*); high-NR folding is interim.
fn canonNr(nr: u64) u64 {
    return switch (nr) {
        231 => 60,
        318 => 61,
        158, 218, 273, 302 => 62,
        else => nr,
    };
}

export fn ring3_trap(f: *TrapFrame) callconv(.c) void {
    // bag check before dispatch: an nr not granted in child_rights is a
    // capability refusal, loud on serial AND visible to the child as
    // -EACCES — not a silent ENOSYS. Bits name CAPABILITIES, not raw
    // numbers: NRs that are the same capability fold to a canonical
    // number first (exit_group 231 -> exit 60), so a bag wider than
    // u64 is not needed while the surface stays small.
    const cnr = canonNr(f.rax);
    if (cnr >= 64 or (child_rights >> @as(u6, @intCast(cnr))) & 1 == 0) {
        say("SEAM REFUSE nr=");
        puthex(f.rax);
        say(" (not in child bag)\n");
        f.rax = @bitCast(@as(i64, -13));
        return;
    }
    const c = &children[cur_child];
    switch (f.rax) {
        1 => { // write(fd, buf, len) -> len
            const buf: [*]const u8 = @ptrFromInt(@as(usize, @intCast(f.rsi)));
            var i: usize = 0;
            while (i < f.rdx) : (i += 1) serPut(buf[i]);
            f.rax = f.rdx;
        },
        20 => { // writev(fd, iov, iovcnt) -> total
            const iov: [*]const u64 = @ptrFromInt(@as(usize, @intCast(f.rsi)));
            var total: u64 = 0;
            var i: usize = 0;
            while (i < f.rdx) : (i += 1) {
                const base: usize = @intCast(iov[i * 2]);
                const len: usize = @intCast(iov[i * 2 + 1]);
                const buf: [*]const u8 = @ptrFromInt(base);
                var n: usize = 0;
                while (n < len) : (n += 1) serPut(buf[n]);
                total += len;
            }
            f.rax = total;
        },
        39 => { // getpid
            f.rax = 1;
        },
        16 => { // ioctl — no ttys exist; ENOTTY is the honest answer
            f.rax = @bitCast(@as(i64, -25));
        },
        12 => { // brk(addr) -> current break; 0 queries
            const want: usize = @intCast(f.rdi);
            if (want == 0 or want < c.brk_base or
                want >= USER_STACK_TOP - USER_STACK_PAGES * 0x1000 - 0x1000)
            {
                f.rax = c.brk; // brk's refusal is returning the old break
            } else {
                var p = c.brk & ~@as(usize, 0xFFF);
                while (p < want) : (p += 0x1000) {
                    if (userEntry(c, p) == 0) {
                        _ = mapUserPage(c, p) orelse break;
                    }
                }
                c.brk = want;
                f.rax = c.brk;
            }
        },
        9 => { // mmap — anonymous private only; file-backed refuses ENODEV
            const len: usize = @intCast(f.rsi);
            if (f.r10 & 0x20 == 0 or len == 0) { // MAP_ANONYMOUS required
                f.rax = @bitCast(@as(i64, -19)); // ENODEV
            } else {
                const base = c.mmap_top;
                var p: usize = 0;
                var ok = true;
                while (p < len) : (p += 0x1000) {
                    if (mapUserPage(c, base + p) == null) { ok = false; break; }
                }
                if (!ok) {
                    f.rax = @bitCast(@as(i64, -12)); // ENOMEM
                } else {
                    if (f.rdx & 2 == 0) setUserWritable(c, base, len, false); // !PROT_WRITE
                    c.mmap_top += (len + 0xFFF) & ~@as(usize, 0xFFF);
                    f.rax = base;
                }
            }
        },
        158 => { // arch_prctl(code, addr) — the TLS seam: FS base per child
            if (f.rdi == 0x1002) { // ARCH_SET_FS
                c.fsbase = f.rsi;
                f.rax = 0;
            } else if (f.rdi == 0x1003) { // ARCH_GET_FS
                f.rax = c.fsbase;
            } else {
                f.rax = @bitCast(@as(i64, -22)); // EINVAL
            }
        },
        218 => f.rax = 1, // set_tid_address — our only tid is the child
        273 => f.rax = 0, // set_robust_list — declared, no robust futexes
        302 => { // prlimit64(pid, res, new, old) — old gets infinity
            if (f.r10 != 0) {
                const old: [*]u64 = @ptrFromInt(@as(usize, @intCast(f.r10)));
                old[0] = ~@as(u64, 0);
                old[1] = ~@as(u64, 0);
            }
            f.rax = 0;
        },
        318 => { // getrandom — TSC-seeded xorshift; non-crypto, said so
            const buf: [*]u8 = @ptrFromInt(@as(usize, @intCast(f.rdi)));
            var s: u64 = rdtsc() ^ f.rsi;
            var i: usize = 0;
            while (i < f.rsi) : (i += 1) {
                s ^= s << 13; s ^= s >> 7; s ^= s << 17;
                buf[i] = @truncate(s);
            }
            f.rax = f.rsi;
        },
        60, 231 => { // exit/exit_group(code) — child dies, frames go back
            last_exit = f.rdi;
            children[cur_child].state = .dead;
            const nf = freeChild(&children[cur_child]);
            say("pmm: reap freed=");
            puthex(nf);
            say("\n");
            if (nextRunnable()) |n| resumeChild(n);
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

// First runnable child after `cur` (wraps); null when the roster is dead.
fn nextRunnable() ?usize {
    for (0..nchildren) |k| {
        const j = (cur_child + 1 + k) % nchildren;
        if (children[j].state == .runnable) return j;
    }
    return null;
}

// Resume child `nxt`: rsp -> its saved frame, CR3 -> its space, then the
// shared pop+iretq tail. Never returns — the current context (kernel stack
// or a dead child's syscall frame) is abandoned by construction.
fn wrmsr(msr: u32, v: u64) void {
    asm volatile ("wrmsr"
        :
        : [c] "{ecx}" (msr), [a] "{eax}" (@as(u32, @truncate(v))), [d] "{edx}" (@as(u32, @truncate(v >> 32))));
}

fn resumeChild(nxt: usize) noreturn {
    const c = &children[nxt];
    cur_child = nxt;
    child_rights = c.rights;
    wrmsr(0xC0000100, c.fsbase); // FS_BASE — the child's TLS home
    asm volatile (
        \\ mov %[fr], %%rsp
        \\ mov %[cr3], %%rax
        \\ mov %%rax, %%cr3
        \\ jmp user_frame_resume
        :
        : [fr] "r" (&c.frame),
          [cr3] "r" (c.pml4),
        : .{ .memory = true });
    unreachable;
}

// The epoch's entry: called (via `call sched_launch` inside koru_spawn_run's
// save block) once all children are primed — resumes the first runnable.
export fn sched_launch() callconv(.c) noreturn {
    resumeChild(nextRunnable() orelse {
        // an all-dead roster must never reach here — fall back to the
        // blocked caller rather than hang
        asm volatile (
            \\ mov saved_rsp(%%rip), %%rsp
            \\ jmp *saved_rip(%%rip)
            ::: .{ .memory = true });
        unreachable;
    });
}

comptime {
    asm (
        \\ .section .text
        \\ .globl user_frame_resume
        \\ user_frame_resume:
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
        \\
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

// Spawn n caller-supplied ELF64 images, one child space each, rung-2
// semantics: all children runnable, the PIT tick rotates them, exit()
// resumes the next runnable child — and the roster draining resumes the
// blocked caller (spawn stays a blocking provider call — it returns the
// last exit code). The kernel is not a schedulable context inside an
// epoch: while children run, only children run; ticks that interrupt
// CPL0 work (the ISR/syscall path itself) see cs&3==0 and do not rotate.
// < 0 on setup refusal: -1 tables, -2 image, -3 over MAXCHILDREN.
pub export fn koru_spawn_run(imgs: [*]const [*]const u8, sizes: [*]const usize, rights: [*]const u64, n: usize) callconv(.c) c_int {
    if (n == 0) return 0;
    if (n > MAXCHILDREN) {
        say("RING3 FAIL: roster over MAXCHILDREN\n");
        return -3;
    }
    nchildren = 0;
    for (0..n) |i| {
        const c = &children[i];
        if (!buildTables(c)) {
            say("RING3 FAIL: page alloc\n");
            return -1;
        }
        const info = loadElf(c, imgs[i][0..sizes[i]]) orelse {
            say("ELF LOAD FAIL\n");
            return -2;
        };
        c.rights = rights[i];
        c.frame = std.mem.zeroes(UserFrame);
        c.frame.rip = info.entry;
        c.frame.cs = 0x23; // user code64
        c.frame.rflags = 0x202; // IF=1 — the child may be ticked mid-flight
        c.frame.rsp = buildStack(c, info) orelse return -1;
        c.brk_base = info.brk_base;
        c.brk = info.brk_base;
        c.mmap_top = MMAP_BASE;
        c.fsbase = 0;
        c.frame.ss = 0x1B; // user data
        c.state = .runnable;
        nchildren += 1;
    }
    loadTables();
    cur_child = 0;
    sched_active = true;
    asm volatile (
        \\ push %rbx
        \\ push %rbp
        \\ push %r12
        \\ push %r13
        \\ push %r14
        \\ push %r15
        \\ mov %%rsp, saved_rsp(%%rip)
        \\ lea 1f(%%rip), %%rax
        \\ mov %%rax, saved_rip(%%rip)
        // call, not fallthrough — sched_launch is noreturn; the pad keeps
        // its entry 16-conformant. saved_rsp predates both, so the exit
        // jmp back to 1: walks only the pushed regs.
        \\ sub $8, %%rsp
        \\ call sched_launch
        \\ 1:
        \\ pop %r15
        \\ pop %r14
        \\ pop %r13
        \\ pop %r12
        \\ pop %rbp
        \\ pop %rbx
        ::: .{ .memory = true });
    sched_active = false;
    say("sched: switches=");
    koru_putdec(sched_switches);
    say("\n");
    return @intCast(last_exit);
}

// Spawn a caller-supplied ELF64 image in a fresh child space. The single-
// child spelling of koru_spawn_run — blocks until the child exits through
// the seam; returns its exit code (< 0 on setup refusal).
pub export fn koru_spawn_elf(image: [*]const u8, size: usize, rights: u64) callconv(.c) c_int {
    var imgs = [_][*]const u8{image};
    var szs = [_]usize{size};
    var rts = [_]u64{rights};
    return koru_spawn_run(&imgs, &szs, &rts, 1);
}

// No-disk evidence path: spawn the embedded child once.
pub fn run() void {
    const st = koru_spawn_elf(&child_elf, child_elf.len, (1 << 1) | (1 << 60));
    say("EMBED SPAWN exit=");
    puthex(@intCast(@as(u32, @bitCast(st))));
    say("\n");
}
