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
// Rights: the bag is class grants (the rights bitmask — dispatcher
// refuses -EACCES, loud on serial, any nr not covered BEFORE dispatch)
// plus object grants (Child.grants[], nid-keyed records the spawn blob
// marshals; an object grant lights its class for dispatch, and arms
// like openat check the object side). This is where the spawn lift's
// bag model becomes load-bearing: exec hands the bag down, the seam
// enforces it.
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
extern fn malloc(size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;
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
const INTERP_BASE: usize = 0x7000_0000; // PT_INTERP loader's ET_DYN bias — clear of mains AND the mmap arena

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
// Kernel stacks are per-child: every live child owns a bounded trap
// context, so a trap path that calls provider depth (fs+ELF load) can
// only burn its own slot — never a bystander's tables (the shared-4KiB
// overflow that read as impossible pmm refusals). Sized for the deepest
// measured chain — childSpawn's loadElfViaFs head buffer + ext2/virtio
// frames — with 4x margin; a parked frame is evacuated into wait_frame,
// never stacked, so the kstack is dead scratch between user epochs.
// Static per-slot because the roster itself is fixed — a dynamic roster
// moves these to pmm frames with it.
const KSTACK: usize = 32 * 1024;
var kstacks: [MAXCHILDREN][KSTACK]u8 align(16) = undefined;

fn kstackTop(n: usize) u64 {
    return @intFromPtr(&kstacks[n]) + KSTACK;
}

// Boot/idle rsp0: the TSS+rsp0_val value before the first child resumes
// and the context all-blocked halts run on. Live traps always land on
// the current child's own stack — resumeChild repoints both.
var kstack: [8192]u8 align(16) = [_]u8{0} ** 8192;

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

// Tick preemption: if the interrupted context was CPL3 and the epoch is
// live, the on-stack frame IS the outgoing child's context — copy it into
// its slot, EOI the tick (the tail-switch never reaches the dispatch
// epilogue's EOI), and hand off to schedLoop. Selection, rotation order,
// and BOTH resumable shapes live in one dispatcher now: a woken kernel
// continuation (kctx != 0) is a real rotation target — switchInto pops
// its pushed block instead of iretq'ing, which is the cell in-place
// surgery could never express. cs&3 != 3 means the tick interrupted CPL0
// work (ISR, syscall, a live continuation) — no user frame to steal, so
// nothing rotates; kernel calls stay non-preemptible.
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
    picEoi(0x20);
    tick_armed = true;
    schedLoop();
}

export fn irq_exc_dispatch(f: *ExcFrame) callconv(.c) void {
    if (f.vec >= 0x20 and f.vec < 0x30) {
        if (f.vec == 0x20) {
            irq_ticks += 1;
            if (irq_ticks == 1) say("irq: timer delivered\n");
            schedPreempt(f);
        } else if (f.vec == 0x21) {
            kbd.irq(); // 8042 scancode → input ring
            // a landed ASCII byte is worth a conin wake; a bare break
            // code is not — the resumed read would just re-block.
            if (kbd.conPending()) wakeKind(.conin);
        } else if (virtio_irq_line != 0xFF and f.vec == 0x20 + @as(u64, virtio_irq_line)) {
            virtio_irq_ack();
            virtio_seen += 1;
            if (virtio_seen == 1) say("irq: virtio delivered\n");
            wakeKind(.blk); // a retired request resumes its parked trap
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
    say(" cs=");
    puthex(f.cs);
    say(" va=");
    puthex(rdcr2());
    if (f.vec == 3) {
        say(" (continued)\n");
        return;
    }
    if (f.rip >= USER_VA_BASE) { // user fault — dump the child's stack: the
        // return addresses on it name the callers, which is the whole
        // debugging story when a real binary dies deep in its own code.
        say("\nstack: ");
        const tail: [*]const u64 = @ptrFromInt(@intFromPtr(&f.rflags));
        const usp = tail[1]; // hardware usp trails rip/cs/rflags in the frame
        var i: usize = 0;
        while (i < 12) : (i += 1) {
            const va = usp + i * 8;
            const e = userEntry(&children[cur_child], va);
            if (e & 1 == 0) break;
            const p: *const u64 = @ptrFromInt((e & ~@as(u64, 0xFFF)) + (va & 0xFFF));
            puthex(p.*);
            say(" ");
        }
    } else { // kernel fault — CPL0 pushes no rsp/ss, so the faulting
        // context's stack lives ABOVE the ExcFrame (older words), not
        // below it. Dump the saved gp regs + the words past the frame.
        say("\nregs:");
        const g: [*]const u64 = @ptrCast(f);
        var i: usize = 0;
        while (i < 15) : (i += 1) {
            say(" ");
            puthex(g[i]);
        }
        say("\nup: ");
        var w: usize = @intFromPtr(f) + @sizeOf(ExcFrame);
        i = 0;
        while (i < 24) : (i += 1) {
            const p: *const u64 = @ptrFromInt(w);
            puthex(p.*);
            say(" ");
            w += 8;
        }
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
pub export var child_entry: u64 = 0; // 1 = syscall gate, 0 = int80 — fork's
                                    // resume frame differs between them
pub export var rsp0_val: u64 = 0; // kernel stack top for the syscall entry
// (child_rights retired — the gate reads the armed child's bag directly)

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

const ChildState = enum { empty, runnable, blocked, zombie, dead };
const MAXCHILDREN: usize = 4;

// The child's scoped fs view: the fs a child was spawned *from* hands
// down this ops record — open/read/read_at/seek/stat/close over opaque
// provider handles. fs-neutral: the ops are the fs's own emitted code
// (ext2 today), ctx is its *Fs; the kernel side only juggles fds 3..7
// and copies through child memory. A child without a view (embedded,
// hostexec, spawn:exec) gets open() == -ENOSYS, not a borrowed fs.
const ChildFsOps = extern struct {
    ctx: ?*anyopaque,
    open: *const fn (ctx: ?*anyopaque, path: [*:0]const u8, flags: c_int) callconv(.c) i64,
    read: *const fn (ctx: ?*anyopaque, h: u64, dst: [*]u8, len: usize) callconv(.c) i64,
    read_at: *const fn (ctx: ?*anyopaque, h: u64, off: u64, dst: [*]u8, len: usize) callconv(.c) i64,
    seek: *const fn (ctx: ?*anyopaque, h: u64, off: i64, whence: u32) callconv(.c) i64,
    stat: *const fn (ctx: ?*anyopaque, h: u64, dst: [*]u8) callconv(.c) i64, // 144B linux stat
    close: *const fn (ctx: ?*anyopaque, h: u64) callconv(.c) void,
    // dup bumps the handle's provider-side refcount and returns the
    // handle to record — fork and spawn-fd-wiring SHARE the open file
    // (POSIX: one offset across dup'd fds), so close must refcount, not
    // free on the first drop.
    dup: *const fn (ctx: ?*anyopaque, h: u64) callconv(.c) i64,
    // key: path → object key (dev<<32|ino) with NO handle — the seam's
    // pre-open grant check; a directory's key names the object a
    // create/unlink/rename mutates.
    key: *const fn (ctx: ?*anyopaque, path: [*:0]const u8) callconv(.c) i64,
    write: *const fn (ctx: ?*anyopaque, h: u64, src: [*]const u8, len: usize) callconv(.c) i64,
    rename: *const fn (ctx: ?*anyopaque, old: [*:0]const u8, new: [*:0]const u8) callconv(.c) i64,
    unlink: *const fn (ctx: ?*anyopaque, path: [*:0]const u8) callconv(.c) i64,
    // open_key: open by object identity — the nr514 openobj arm's
    // provider half. No path exists to walk; the key IS the name.
    open_key: *const fn (ctx: ?*anyopaque, key: u64, flags: c_int) callconv(.c) i64,
};

const WaitKind = enum { none, conin, blk, exit, pipe };

// fd slots are projections over typed seam endpoints, not bare provider
// handles: stdio are real entries (conin/conout), fs a view handle,
// pipe_r/pipe_w ends of a kernel ring. read/write/close dispatch on the
// kind, never on the number — closing fd0 detaches like any discharge.
const FdKind = enum { none, conin, conout, fs, pipe_r, pipe_w };

// ---- the bag: class grants + nid-scoped object grants ------------------
// DESIGN-0001 §8.6's grant {handle, verbs, as} distilled to the syscall
// edge: obj is the object key in the pin keyspace (dev<<32|ino — the same
// number a musl child computes from fstat's st_dev/st_ino), cap is the
// canonical class the grant serves (canonNr domain, <64), verbs attenuate.
// The u64 `rights` mask is NOT a second mechanism — it is the bag's class
// projection: bit C set == grant {cap:C, obj:ANY}. grants[] holds only the
// object-scoped entries; the seam gate passes a class if EITHER form names
// it, and object-bearing arms (openat) then check the object side.
const MAXGRANTS = 8;
const V_READ: u8 = 1;
const V_WRITE: u8 = 2;
const V_EXEC: u8 = 4;
const Grant = extern struct { obj: u64, verbs: u8, cap: u8, pad: [6]u8 };

// The spawn blob is a section stream — 'KGRB' + nsec + TLVs. argv is one
// section, grants another; env lands as a third when F5 gets its rung.
const SECT_MAGIC: u32 = 0x4252474B; // 'KGRB'
const TAG_ARGV: u16 = 1;
const TAG_GRANT: u16 = 2;

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
    rights: u64 = 0,                 // class-grant projection of the bag
    grants: [MAXGRANTS]Grant = undefined, // object-scoped grants (ngrants
                                     // is the bound — never read past it)
    ngrants: u8 = 0,
    state: ChildState = .empty,
    fsv: ?*const ChildFsOps = null, // scoped fs view (the spawning fs)
    fds: [8]u64 = .{0} ** 8,        // endpoint id by kind: fs handle or pipe idx
    fdkinds: [8]FdKind = .{.none} ** 8,
    fdverbs: [8]u8 = .{0} ** 8,     // the fd IS a grant — V_READ/V_WRITE
                                    // recorded when the projection was
                                    // minted; read/write dispatch checks
                                    // the verb, not just the kind
    // blocking is a kernel continuation, not a rebuilt user frame: kblock
    // pushes callee-saved on this child's own kstack and stores the rsp
    // here; a waker just flips .runnable and the next switchInto pops the
    // block and returns into the parked call — the syscall completes
    // itself on whatever entry path it arrived on.
    wait_kind: WaitKind = .none,    // what the .blocked child waits on
    wait_pid: usize = 0,            // .exit: roster slot of the awaited child
    wait_pipe: usize = 0,           // .pipe: which ring the child waits on
    kctx: u64 = 0,                  // saved kernel rsp while blocked mid-call
    spawn_ret: i64 = 0,             // .exit wake: the dead child's status
    waitable: bool = false,         // detached spawn: hold status in a
                                    // .zombie slot until wait() claims it
    exit_status: i64 = 0,           // zombie payload — claimed by wait()
    ursp: u64 = 0,                  // user rsp at syscall entry — child_ursp
                                    // is a per-syscall global; a blocked
                                    // syscall outlives it, so we snapshot
                                    // here and the epilogue reads it back
};

var children: [MAXCHILDREN]Child = .{ .{}, .{}, .{}, .{} };
var nchildren: usize = 0;
var cur_child: usize = 0;
var sched_active = false;
pub export var sched_switches: u64 = 0;
pub export var kctx_resumes: u64 = 0;
pub export var tick_kctx: u64 = 0;
pub export var forks: u64 = 0;      // nr57 fork calls served
pub export var fork_pages: u64 = 0; // user pages the copies moved
// schedPreempt arms this before entering schedLoop; switchInto consumes
// it — the first dispatch after a tick is tick-driven by construction.
var tick_armed: bool = false;

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
// the kernel identity and refuses by name), ET_DYN maps at `dyn_bias` +
// p_vaddr (static-pie mains take USER_VA_BASE; the PT_INTERP loader takes
// INTERP_BASE so the two never collide). Pages are zeroed at alloc, so
// bss (memsz > filesz) needs no fill. A PT_INTERP segment doesn't load —
// its path is captured into `ipath` and the caller resolves it through
// the child's fs view (dynamic images without one still refuse by name).
fn loadElf(c: *Child, b: []const u8, dyn_bias: usize, ipath: ?[]u8, ilen: ?*usize) ?ElfInfo {
    if (ilen != null) ilen.?.* = 0;
    if (b.len < EHDR or b[0] != 0x7F or b[1] != 'E' or b[2] != 'L' or
        b[3] != 'F' or b[4] != 2 or b[5] != 1) return null;
    const etype = u16le(b, 16);
    if (u16le(b, 18) != 0x3E or (etype != 2 and etype != 3)) return null;
    const bias: usize = if (etype == 3) dyn_bias else 0;
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
        if (ptype == 3) { // PT_INTERP — capture the loader path; the
            // caller opens it through the fs view and loads it at
            // INTERP_BASE as a second ET_DYN image.
            const off: usize = @intCast(u64le(b, ph + 8));
            const filesz: usize = @intCast(u64le(b, ph + 32));
            if (ilen != null and ipath != null and off + filesz <= b.len and
                filesz <= ipath.?.len) {
                @memcpy(ipath.?.ptr, b[off .. off + filesz]);
                ilen.?.* = filesz;
            }
            continue;
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

// Child-memory access through the identity map, not the pointer value:
// the trap handler runs on the child's CR3, so a bare @ptrFromInt would
// work — but only for RW pages (CR0.WP). Via userPhys the access is the
// page's identity twin: W-bit-independent, and it self-checks mapping.
fn userByte(c: *Child, va: usize) u8 {
    if (userEntry(c, va) & 1 == 0) return 0;
    return @as([*]const u8, @ptrFromInt(userPhys(c, va) + (va & 0xFFF)))[0];
}
fn userPut(c: *Child, va: usize, b: u8) void {
    if (userEntry(c, va) & 1 == 0) return;
    @as([*]u8, @ptrFromInt(userPhys(c, va) + (va & 0xFFF)))[0] = b;
}
fn userPath(c: *Child, va: usize, buf: []u8) ?[]u8 {
    var n: usize = 0;
    while (n < buf.len - 1) : (n += 1) {
        if (userEntry(c, va + n) & 1 == 0) return null;
        const ch = userByte(c, va + n);
        buf[n] = ch;
        if (ch == 0) return buf[0..n];
    }
    return null; // unterminated within the cap — refuse
}
fn copyToUser(c: *Child, va: usize, src: []const u8) usize {
    var n: usize = 0;
    while (n < src.len) : (n += 1) {
        if (userEntry(c, va + n) & 1 == 0) break;
        userPut(c, va + n, src[n]);
    }
    return n;
}
fn copyFromUser(c: *Child, va: usize, dst: []u8) usize {
    var n: usize = 0;
    while (n < dst.len) : (n += 1) {
        if (userEntry(c, va + n) & 1 == 0) break;
        dst[n] = userByte(c, va + n);
    }
    return n;
}

// MAXARGS bounds the argv vector a spawn blob may mint — argv[] lives on
// the child's own stack, but argc past the cap is a malformed request,
// refused loudly as -E2BIG before any loading happens.
const MAXARGS = 16;

// Lay out the ELF-ABI entry vector: `ablob` is the argument block —
// argv strings packed back-to-back, each NUL-terminated (a trailing
// non-terminated tail counts as the last arg; consecutive NULs mint
// empty args, honestly). argc/argv[]/NULL/envp-NULL/auxv is the musl
// _start contract; strings sit at the very top of the stack window.
fn buildStack(c: *Child, info: ElfInfo, at_base: u64, ablob: []const u8) ?usize {
    var i: usize = 0;
    const sbase = USER_STACK_TOP - USER_STACK_PAGES * 0x1000;
    while (i < USER_STACK_PAGES) : (i += 1) {
        _ = mapUserPage(c, sbase + i * 0x1000) orelse return null;
    }
    // the arg block: copy it down from the top, then walk NUL boundaries
    // for segment starts — argv[i] = blob_base + start[i].
    var starts: [MAXARGS]usize = undefined;
    var argc: usize = 0;
    var bi: usize = 0;
    while (bi < ablob.len and argc < MAXARGS) {
        starts[argc] = bi;
        argc += 1;
        while (bi < ablob.len and ablob[bi] != 0) bi += 1;
        bi += 1;
    }
    if (bi < ablob.len) return null; // more than MAXARGS — refused upstream
    // The on-stack block always ends NUL-terminated: an unterminated
    // tail is a legal last arg by the blob contract, but the child reads
    // strings with %s — without the terminator it walks one byte past
    // the top of the mapped window and faults at USER_STACK_TOP itself.
    var blen = ablob.len;
    if (blen == 0 or ablob[blen - 1] != 0) blen += 1;
    var top = USER_STACK_TOP;
    var n: usize = 0;
    while (n < blen) : (n += 1) {
        const va = top - blen + n;
        const phys = userPhys(c, va);
        const dst: *u8 = @ptrFromInt(phys + (va & 0xFFF));
        dst.* = if (n < ablob.len) ablob[n] else 0;
    }
    top -= blen;
    const blob_base = top;
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
    // the vector: argc, argv, NULL, envp NULL, auxv pairs, AT_NULL.
    // AT_BASE is present only when an interpreter was loaded — ld.so
    // reads it as its own load bias; the main binary's phdrs/entry stay
    // in AT_PHDR/AT_ENTRY either way.
    var auxv: [16][2]u64 = undefined;
    var na: usize = 0;
    const fixed = [_][2]u64{
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
    };
    for (fixed) |p| { auxv[na] = p; na += 1; }
    if (at_base != 0) { auxv[na] = .{ 7, at_base }; na += 1; }
    auxv[na] = .{ 0, 0 }; na += 1;
    const vec_slots = 1 + argc + 1 + 1 + na * 2; // argc argv[] NUL envpNUL pairs
    const sp = (top - vec_slots * 8) & ~@as(usize, 0xF);
    var at = sp;
    userWrite(c, at, argc); at += 8;        // argc
    for (0..argc) |k| {
        userWrite(c, at, blob_base + starts[k]); at += 8;
    }
    userWrite(c, at, 0); at += 8;          // argv NULL
    userWrite(c, at, 0); at += 8;          // envp NULL
    for (auxv[0..na]) |pair| {
        userWrite(c, at, pair[0]); at += 8;
        userWrite(c, at, pair[1]); at += 8;
    }
    return sp;
}

// Load an ELF image through the child's fs view — the same ops record the
// child itself would use for openat()/read(). Header and phdrs go through
// a small stack buffer; each PT_LOAD streams straight into its mapped
// user pages via read_at — the kernel never buffers a whole image (the
// bump heap can't afford a second copy of ld.so). dyn_bias lands ET_DYN
// at the given base (mains take USER_VA_BASE, the interp INTERP_BASE);
// ET_EXEC maps at p_vaddr outright. PT_INTERP is captured into ipath for
// the caller to resolve — through the view, same rule as loadElf.
fn loadElfViaFs(c: *Child, path: []const u8, dyn_bias: usize, ipath: ?[]u8, ilen: ?*usize) ?ElfInfo {
    const ops = c.fsv orelse return null;
    if (ilen != null) ilen.?.* = 0;
    var z: [256]u8 = undefined;
    if (path.len >= z.len) return null;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const h = ops.open(ops.ctx, @ptrCast(&z), 0); // O_RDONLY — ELF load
    if (h < 0) return null;
    const fh: u64 = @intCast(h);
    var hd: [4096]u8 = undefined;
    const hn = ops.read_at(ops.ctx, fh, 0, &hd, hd.len);
    if (hn < @as(i64, EHDR)) { ops.close(ops.ctx, fh); return null; }
    const b: []const u8 = hd[0..@intCast(hn)];
    if (b[0] != 0x7F or b[1] != 'E' or b[2] != 'L' or b[3] != 'F' or
        b[4] != 2 or b[5] != 1) { ops.close(ops.ctx, fh); return null; }
    const etype = u16le(b, 16);
    if (u16le(b, 18) != 0x3E or (etype != 2 and etype != 3)) { ops.close(ops.ctx, fh); return null; }
    const bias: usize = if (etype == 3) dyn_bias else 0;
    const entry: usize = @intCast(u64le(b, 24));
    const phoff: usize = @intCast(u64le(b, 32));
    const phentsz: usize = u16le(b, 54);
    const phnum: usize = u16le(b, 56);
    if (phnum == 0 or phentsz < PHDR or phoff + phnum * phentsz > b.len) {
        ops.close(ops.ctx, fh);
        return null;
    }
    var phdr_va: usize = 0;
    var max_va: usize = 0;
    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const ph = phoff + i * phentsz;
        const ptype = u32le(b, ph);
        if (ptype == 3) { // PT_INTERP — capture the loader path for the
            // caller to stream as a second image (the loader itself).
            const off: usize = @intCast(u64le(b, ph + 8));
            const filesz: usize = @intCast(u64le(b, ph + 32));
            if (ilen != null and ipath != null and filesz <= ipath.?.len) {
                _ = ops.read_at(ops.ctx, fh, off, ipath.?.ptr, filesz);
                ilen.?.* = filesz;
            }
            continue;
        }
        if (ptype != 1) continue; // PT_LOAD only
        const off: usize = @intCast(u64le(b, ph + 8));
        const vaddr: usize = @intCast(u64le(b, ph + 16));
        const filesz: usize = @intCast(u64le(b, ph + 32));
        const memsz: usize = @intCast(u64le(b, ph + 40));
        if (filesz > memsz) { ops.close(ops.ctx, fh); return null; }
        const va = bias + vaddr;
        if (va + memsz > max_va) max_va = va + memsz;
        if (va < USER_VA_BASE) { ops.close(ops.ctx, fh); return null; }
        var p = va & ~@as(usize, 0xFFF);
        while (p < va + memsz) : (p += 0x1000) {
            _ = mapUserPage(c, p) orelse { ops.close(ops.ctx, fh); return null; };
        }
        var n: usize = 0;
        while (n < filesz) {
            const take = @min(@as(usize, 0x1000) - ((va + n) & 0xFFF), filesz - n);
            const dst: [*]u8 = @ptrFromInt(userPhys(c, va + n) + ((va + n) & 0xFFF));
            const rn = ops.read_at(ops.ctx, fh, off + n, dst, take);
            if (rn != @as(i64, @intCast(take))) { ops.close(ops.ctx, fh); return null; }
            n += take;
        }
        if (phoff >= off and phoff + phnum * phentsz <= off + filesz)
            phdr_va = va + (phoff - off);
    }
    if (phdr_va == 0 and phnum != 0) {
        // phdrs not inside any PT_LOAD — park a copy on its own page the
        // same way loadElf does; they're already in the head buffer.
        const pv = USER_VA_BASE + 0x200000 - 0x1000;
        _ = mapUserPage(c, pv) orelse { ops.close(ops.ctx, fh); return null; };
        const dst: [*]u8 = @ptrFromInt(userPhys(c, pv));
        var n: usize = 0;
        while (n < phnum * phentsz) : (n += 1) dst[n] = b[phoff + n];
        phdr_va = pv;
    }
    ops.close(ops.ctx, fh);
    return .{ .entry = bias + entry, .phdr_va = phdr_va, .phent = phentsz, .phnum = phnum, .bias = bias, .brk_base = (max_va + 0xFFF) & ~@as(usize, 0xFFF) };
}

fn rdcr2() u64 {
    return asm volatile ("mov %cr2, %[v]"
        : [v] "=r" (-> u64),
    );
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

// argv[0] for the next spawn: the exec path's basename, written by the
// caller before koru_spawn_elf — POSIX's own convention (argv0 is the
// name the program was invoked as, which for a multi-call binary IS the
// program). Default is the embedded-child name.
pub export var child_arg0: [64]u8 = "child.elf".* ++ [_]u8{0} ** 55;

// Canonical capability number for a syscall nr. Bits 0..63 name
// capabilities; for NRs <64 the bit IS the Linux nr, so a bag reads
// like a syscall mask. NRs ≥64 have no bit — they fold onto reserved
// caps: 62 = "describe/modify own process metadata" (arch_prctl FS,
// set_tid_address, set_robust_list, prlimit64), 61 = "entropy"
// (getrandom), and 231 -> 60 (exit_group IS exit for single-threaded
// children). The mask is the bag's CLASS side; nid-scoped object grants
// live in Child.grants[] and arrive through the spawn blob's KGRB
// section stream (concepts/frag-bag-*).
fn canonNr(nr: u64) u64 {
    return switch (nr) {
        257 => 2, // openat folds to open — one "fs object" capability
        // path-mutation verbs share the fs-object class: creat(85),
        // rename(82)/renameat(264)/renameat2(316), unlink(87)/unlinkat(263).
        // The class bit grants mount-wide; object grants narrow them by
        // verb — the mutated object is always a directory's key.
        85, 82, 264, 316, 87, 263 => 2,
        231 => 60,
        318 => 61,
        158, 218, 273, 302 => 62,
        14 => 62, // rt_sigprocmask — proc-self metadata, no signals exist
        72 => 62, // fcntl folds to the proc-self group — our handles carry no flag state
        // koru's own ABI lives at 512+, out of musl's namespace — nr57 is
        // REAL fork now (musl _Fork sends it with zero args); clone(56)
        // folds to the same "create a child" cap — the flag-shape refusal
        // is the arm's job, not the bag's. Bits 57/58 name the caps.
        56 => 57,
        512 => 57,
        513 => 58,
        514 => 2, // openobj — the object axis' open; folds to the fs-object
                  // class and the key argument IS the object it names
        else => nr,
    };
}

// The seam gate's question: does ANY grant — class bit or object record —
// name this capability? An object grant lights its class for dispatch;
// the arm's object check is what separates "mount-wide" from "this nid".
fn bagAllows(c: *const Child, cnr: u64) bool {
    if ((c.rights >> @as(u6, @intCast(cnr))) & 1 == 1) return true;
    for (c.grants[0..c.ngrants]) |g| if (g.cap == cnr) return true;
    return false;
}

// Does an object grant cover (cap, obj, verbs)? Called when the class bit
// is absent — the bit would already cover every object and verb.
fn grantCovers(c: *const Child, cnr: u64, obj: u64, verbs: u8) bool {
    for (c.grants[0..c.ngrants]) |g|
        if (g.cap == cnr and g.obj == obj and (g.verbs & verbs) == verbs) return true;
    return false;
}

// Attenuation, §8.6's "never amplify": a minted object grant must be
// covered by the parent's own bag — a class bit covers every object, an
// object grant covers the same object at a subset of its verbs.
fn parentCovers(p: *const Child, g: Grant) bool {
    if ((p.rights >> @as(u6, @intCast(g.cap))) & 1 == 1) return true;
    for (p.grants[0..p.ngrants]) |pg|
        if (pg.cap == g.cap and pg.obj == g.obj and (pg.verbs & g.verbs) == g.verbs) return true;
    return false;
}

fn readU16(b: []const u8, off: usize) u16 {
    return @as(u16, b[off]) | (@as(u16, b[off + 1]) << 8);
}

fn readU32(b: []const u8, off: usize) u32 {
    return @as(u32, readU16(b, off)) | (@as(u32, readU16(b, off + 2)) << 16);
}

fn readU64(b: []const u8, off: usize) u64 {
    return @as(u64, readU32(b, off)) | (@as(u64, readU32(b, off + 4)) << 32);
}

// ---- the child's fs view ---------------------------------------------------
// fd slots 3..7 hold provider handles minted by fsv.open; the provider
// owns the handle (ino+pos) — the kernel side translates fds, copies
// through child memory via the identity map, and gates mutation on the
// fd's recorded verbs (fdverbs — the projection IS a grant) plus the
// bag's W-verb object check on the resolved key. A child with no view
// still gets open() == -ENOSYS, not a borrowed fs.

var fsbounce: [4096]u8 = undefined;

// Split "a/b/c" → parent path in buf ("a/b"; "" for a root leaf — the
// empty path resolves to the root directory, ino 2, by lookupPath's
// walk). Every path-mutating op's grant names this directory object.
fn parentPath(p: []const u8, buf: []u8) []u8 {
    var n: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| {
        if (i > 0) {
            n = @min(i, buf.len - 1);
            @memcpy(buf[0..n], p[0..n]);
        }
    }
    return buf[0..n];
}

// The seam's object check, pre-open: a bag without the open class bit
// narrows the view to named objects — the provider resolves the object
// key (dev<<32|ino) WITHOUT minting a handle, and a grant
// {cap:2, obj:key, verbs} must match. Write modes need W; O_CREAT on a
// missing path names the parent DIRECTORY (that's the mutated object);
// the refusal arrives before any handle exists.
fn openCovered(c: *Child, ops: *const ChildFsOps, p: [*:0]const u8, flags: u64) i64 {
    const mode: u8 = @intCast(flags & 3);
    var need: u8 = switch (mode) {
        0 => V_READ,
        1 => V_WRITE,
        else => V_READ | V_WRITE,
    };
    if ((flags & 0o1000) != 0) need |= V_WRITE; // O_TRUNC mutates the file
    const k = ops.key(ops.ctx, p);
    if (k >= 0) {
        if (grantCovers(c, 2, @bitCast(k), need)) return 0;
        say("SEAM REFUSE openat obj=");
        puthex(@bitCast(k));
        if (mode == 0) say(" (no R grant)") else say(" (no W grant)");
        say("\n");
        return -13;
    }
    if ((flags & 0o100) == 0) return k; // ENOENT passes through
    var db: [256]u8 = undefined;
    const dp = parentPath(std.mem.span(p), &db);
    db[dp.len] = 0;
    const dk = ops.key(ops.ctx, @ptrCast(&db));
    if (dk < 0) return dk;
    if (grantCovers(c, 2, @bitCast(dk), V_WRITE)) return 0;
    say("SEAM REFUSE create dir-obj=");
    puthex(@bitCast(dk));
    say(" (no W grant)\n");
    return -13;
}

fn childOpen(c: *Child, pva: usize, flags: u64) i64 {
    const ops = c.fsv orelse return -38; // ENOSYS — this child has no fs view
    var pb: [256]u8 = undefined;
    const p = userPath(c, pva, &pb) orelse return -14; // EFAULT
    pb[p.len] = 0;
    // The class bit covers every object+verb (mount-wide); without it
    // the object-scoped check runs against the resolved key.
    if ((c.rights >> 2) & 1 == 0) {
        const cov = openCovered(c, ops, @ptrCast(&pb), flags);
        if (cov < 0) return cov;
    }
    const h = ops.open(ops.ctx, @ptrCast(&pb), @intCast(flags));
    if (h < 0) return h; // provider's errno passes through (ENOENT &c.)
    var fd: usize = 3;
    while (fd < c.fds.len) : (fd += 1) {
        if (c.fdkinds[fd] == .none) break;
    }
    if (fd == c.fds.len) {
        ops.close(ops.ctx, @intCast(h));
        return -24; // EMFILE
    }
    c.fds[fd] = @intCast(h);
    c.fdkinds[fd] = .fs;
    const mode: u8 = @intCast(flags & 3);
    c.fdverbs[fd] = switch (mode) {
        0 => V_READ,
        1 => V_WRITE,
        else => V_READ | V_WRITE,
    };
    return @intCast(fd);
}

// nr514 openobj(key, flags) — koru's object-axis open. There is no
// path: the key argument IS the object, so for an object-grant child
// the grant check is the syscall itself — grant{cap:2, obj:key} must
// name the same key at the same verbs. A class-bit child is
// mount-wide as always. This is the arm a nid-scoped bag was built
// for: identity as the name, no projection in between.
fn childOpenObj(c: *Child, key: u64, flags: u64) i64 {
    const ops = c.fsv orelse return -38; // ENOSYS — no fs view to serve it
    const mode: u8 = @intCast(flags & 3);
    var need: u8 = switch (mode) {
        0 => V_READ,
        1 => V_WRITE,
        else => V_READ | V_WRITE,
    };
    if ((flags & 0o1000) != 0) need |= V_WRITE; // O_TRUNC mutates the file
    if ((flags & 0o100) != 0) return -38; // O_CREAT needs a directory — paths only
    if ((c.rights >> 2) & 1 == 0 and !grantCovers(c, 2, key, need)) {
        say("SEAM REFUSE openobj obj=");
        puthex(key);
        say(" (no nid grant)\n");
        return -13;
    }
    const h = ops.open_key(ops.ctx, key, @intCast(flags));
    if (h < 0) return h;
    var fd: usize = 3;
    while (fd < c.fds.len) : (fd += 1) {
        if (c.fdkinds[fd] == .none) break;
    }
    if (fd == c.fds.len) {
        ops.close(ops.ctx, @intCast(h));
        return -24; // EMFILE
    }
    c.fds[fd] = @intCast(h);
    c.fdkinds[fd] = .fs;
    c.fdverbs[fd] = switch (mode) {
        0 => V_READ,
        1 => V_WRITE,
        else => V_READ | V_WRITE,
    };
    return @intCast(fd);
}

// write(1) on an .fs fd: the fd's verbs were fixed at open — a read
// projection refuses EBADF like POSIX, the provider never re-checks.
fn childWrite(c: *Child, fd: usize, buva: u64, want: u64) i64 {
    const ops = c.fsv orelse return -38;
    var total: i64 = 0;
    var off: u64 = 0;
    while (off < want) {
        const chunk: usize = @intCast(@min(@as(u64, fsbounce.len), want - off));
        const got = copyFromUser(c, @intCast(buva + off), fsbounce[0..chunk]);
        if (got == 0) return if (total == 0) -14 else total; // EFAULT
        const n = ops.write(ops.ctx, c.fds[fd], &fsbounce, got);
        if (n <= 0) return if (total == 0) n else total;
        total += n;
        off += @intCast(n);
        if (n < got) break; // provider stopped short — don't spin
    }
    return total;
}

// rename/unlink: the mutated objects are the parent DIRECTORIES — a
// bag without the fs-object class bit must hold {cap:2, obj:dirkey, +W}
// for each directory the operation touches.
fn childRename(c: *Child, ova: usize, nva: usize) i64 {
    const ops = c.fsv orelse return -38;
    var ob: [256]u8 = undefined;
    var nb: [256]u8 = undefined;
    const op = userPath(c, ova, &ob) orelse return -14;
    const np = userPath(c, nva, &nb) orelse return -14;
    ob[op.len] = 0;
    nb[np.len] = 0;
    if ((c.rights >> 2) & 1 == 0) {
        var d1: [256]u8 = undefined;
        var d2: [256]u8 = undefined;
        const p1 = parentPath(op, &d1);
        const p2 = parentPath(np, &d2);
        d1[p1.len] = 0;
        d2[p2.len] = 0;
        const k1 = ops.key(ops.ctx, @ptrCast(&d1));
        const k2 = ops.key(ops.ctx, @ptrCast(&d2));
        if (k1 < 0) return k1;
        if (k2 < 0) return k2;
        if (!grantCovers(c, 2, @bitCast(k1), V_WRITE) or
            !grantCovers(c, 2, @bitCast(k2), V_WRITE))
        {
            say("SEAM REFUSE rename dir-objs=");
            puthex(@bitCast(k1));
            say("/");
            puthex(@bitCast(k2));
            say(" (no W grant)\n");
            return -13;
        }
    }
    return ops.rename(ops.ctx, @ptrCast(&ob), @ptrCast(&nb));
}

fn childUnlink(c: *Child, pva: usize) i64 {
    const ops = c.fsv orelse return -38;
    var pb: [256]u8 = undefined;
    const p = userPath(c, pva, &pb) orelse return -14;
    pb[p.len] = 0;
    if ((c.rights >> 2) & 1 == 0) {
        var db: [256]u8 = undefined;
        const dp = parentPath(p, &db);
        db[dp.len] = 0;
        const dk = ops.key(ops.ctx, @ptrCast(&db));
        if (dk < 0) return dk;
        if (!grantCovers(c, 2, @bitCast(dk), V_WRITE)) {
            say("SEAM REFUSE unlink dir-obj=");
            puthex(@bitCast(dk));
            say(" (no W grant)\n");
            return -13;
        }
    }
    return ops.unlink(ops.ctx, @ptrCast(&pb));
}

fn childRead(c: *Child, fdu: u64, buva: u64, want: u64) i64 {
    const ops = c.fsv orelse return -38;
    if (fdu >= c.fds.len) return -9;
    const fd: usize = @intCast(fdu);
    if (fd < 3 or c.fds[fd] == 0) return -9; // EBADF
    var total: i64 = 0;
    var off: u64 = 0;
    while (off < want) {
        const chunk: usize = @intCast(@min(@as(u64, fsbounce.len), want - off));
        const n = ops.read(ops.ctx, c.fds[fd], &fsbounce, chunk);
        if (n <= 0) break;
        const got = copyToUser(c, @intCast(buva + off), fsbounce[0..@intCast(n)]);
        total += @intCast(got);
        off += got;
        if (got < n or n < chunk) break; // EFAULT mid-copy or EOF/short
    }
    return total;
}

fn childPread(c: *Child, fdu: u64, buva: u64, want: u64, pos: u64) i64 {
    const ops = c.fsv orelse return -38;
    if (fdu >= c.fds.len) return -9;
    const fd: usize = @intCast(fdu);
    if (fd < 3 or c.fds[fd] == 0) return -9;
    var total: i64 = 0;
    var off: u64 = 0;
    while (off < want) {
        const chunk: usize = @intCast(@min(@as(u64, fsbounce.len), want - off));
        const n = ops.read_at(ops.ctx, c.fds[fd], pos + off, &fsbounce, chunk);
        if (n <= 0) break;
        const got = copyToUser(c, @intCast(buva + off), fsbounce[0..@intCast(n)]);
        total += @intCast(got);
        off += got;
        if (got < n or n < chunk) break;
    }
    return total;
}

fn childSeek(c: *Child, fdu: u64, off: i64, whence: u32) i64 {
    const ops = c.fsv orelse return -38;
    if (fdu >= c.fds.len) return -9;
    const fd: usize = @intCast(fdu);
    if (fd < 3 or c.fds[fd] == 0) return -9;
    return ops.seek(ops.ctx, c.fds[fd], off, whence);
}

// File-backed private mmap: fd resolves through the fs view like open's
// siblings, pages come from the frame allocator, and the fill reads the
// file straight into the mapped pages (one copy — ops write into the
// identity VA). MAP_FIXED honors the address inside the user window when
// the range is free; an already-mapped page is reused, not remapped.
fn childMmapFile(c: *Child, addru: u64, len: usize, prot: u64, flags: u64, fdu: u64, off: u64) i64 {
    const ops = c.fsv orelse return -38;
    if (flags & 0x01 != 0) return -95; // EOPNOTSUPP — shared maps need write-through
    if (off & 0xFFF != 0) return -22; // EINVAL — file offset must be page-aligned
    if (fdu >= c.fds.len) return -9;
    const fd: usize = @intCast(fdu);
    if (fd < 3 or c.fds[fd] == 0) return -9; // EBADF
    var base: usize = 0;
    if (flags & 0x10 != 0 and addru != 0) { // MAP_FIXED
        base = @intCast(addru);
        if (base & 0xFFF != 0 or base < USER_VA_BASE or base + len > USER_VA_END) return -22;
    } else {
        base = c.mmap_top;
        c.mmap_top += (len + 0xFFF) & ~@as(usize, 0xFFF);
    }
    var p: usize = 0;
    while (p < len) : (p += 0x1000) {
        if (userEntry(c, base + p) & 1 == 0) {
            _ = mapUserPage(c, base + p) orelse return -12; // ENOMEM
        }
        const dst: [*]u8 = @ptrFromInt(userPhys(c, base + p));
        const take = @min(@as(usize, 0x1000), len - p);
        const n = ops.read_at(ops.ctx, c.fds[fd], off + p, dst, take);
        if (n < 0) return n; // provider errno passes through
    }
    // prot applies to the FINAL mapping, not just fresh pages: ld.so
    // reserves a span PROT_NONE then MAP_FIXEDs each LOAD with its real
    // prot — reused pages must pick up the new W bit, not keep the old.
    setUserWritable(c, base, len, prot & 2 != 0);
    return @intCast(base);
}

fn childFstat(c: *Child, fdu: u64, stva: u64) i64 {
    if (fdu >= c.fds.len) return -9;
    var st: [144]u8 = std.mem.zeroes([144]u8);
    const fd: usize = @intCast(fdu);
    switch (c.fdkinds[fd]) {
        .none => return -9,
        .conin, .conout => {
            // stdio: chrdev, 0620 — the console has no size to name
            stw(&st, 24, 0o20620);
            stw(&st, 16, 1); // nlink
        },
        .pipe_r, .pipe_w => {
            // a fifo, honestly named — musl isatty/fstat probing sees S_IFIFO
            stw(&st, 24, 0o10600);
            stw(&st, 16, 1);
        },
        .fs => {
            const ops = c.fsv orelse return -38;
            if (ops.stat(ops.ctx, c.fds[fd], &st) < 0) return -9;
        },
    }
    const n = copyToUser(c, @intCast(stva), &st);
    return if (n < 144) -14 else 0;
}
fn stw(st: *[144]u8, off: usize, v: u64) void {
    for (0..8) |i| st[off + i] = @truncate(v >> @intCast(i * 8));
}

// read(0): drain the console byte ring into the user buffer. An empty
// ring is a real block — kblock suspends this very call on the child's
// own kstack and IRQ1's wake resumes it; the next loop iteration drains
// the landed byte and returns through the normal syscall path.
fn coninRead(c: *Child, f: *TrapFrame) i64 {
    const want: usize = @intCast(f.rdx);
    if (want == 0) return 0;
    const bva: usize = @intCast(f.rsi);
    while (true) {
        var n: usize = 0;
        while (n < want) : (n += 1) {
            const ch = kbd.conByte() orelse break;
            const va = bva + n;
            if (userEntry(c, va) & 1 == 0) break;
            const ub: [*]u8 = @ptrFromInt(userPhys(c, va) + (va & 0xFFF));
            ub[0] = ch;
        }
        if (n != 0) return @intCast(n);
        if (userEntry(c, bva) & 1 == 0) return -14; // EFAULT — no page for a byte
        // Check-under-mask then park: the byte must not land between the
        // drain's empty verdict and the blocked mark, or nobody wakes us.
        asm volatile ("cli" ::: .{ .memory = true });
        if (!kbd.conPending()) {
            kblock(.conin); // returns with IF=1 — a wake happened
        } else {
            asm volatile ("sti" ::: .{ .memory = true });
        }
    }
}

// ---- pipes: a seam is a bounded kernel ring with refcounted ends --------
// pipe() mints one ring and two fd entries pointing at it; spawn wiring
// clones entries (bumping the end's refs); close/exit decrements. The
// wait key is .pipe + wait_pipe idx — read-or-block on empty, write-or-
// block on full, exactly the conin shape. Last writer gone -> drain-then-
// EOS; last reader gone -> writer wakes to -EPIPE. Wake is mark-only like
// every other kind: the recheck loop is what actually sees EOS/EPIPE.
const NPIPES = 8;
const Pipe = struct {
    used: bool = false,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    rrefs: u8 = 0,
    wrefs: u8 = 0,
    buf: [2048]u8 = undefined,
};
var pipes: [NPIPES]Pipe = .{Pipe{}} ** NPIPES;
pub export var pipe_reads: u64 = 0;
pub export var pipe_writes: u64 = 0;
pub export var pipe_rwaits: u64 = 0;
pub export var pipe_wwaits: u64 = 0;

// Mark-only wake for every .pipe waiter on this ring — called after any
// endpoint ref change or buffer activity; the woken call rechecks.
fn wakePipe(idx: usize) void {
    for (0..nchildren) |i| {
        const p = &children[i];
        if (p.state == .blocked and p.wait_kind == .pipe and
            p.wait_pipe == idx) p.state = .runnable;
    }
}

fn pipeCreate() ?usize {
    for (0..NPIPES) |i| {
        if (!pipes[i].used) {
            pipes[i] = .{ .used = true, .rrefs = 1, .wrefs = 1 };
            return i;
        }
    }
    return null;
}

fn pipeReadEnd(c: *Child, idx: usize, buva: u64, want: u64) i64 {
    if (want == 0) return 0;
    const p = &pipes[idx];
    while (true) {
        asm volatile ("cli" ::: .{ .memory = true });
        if (p.count > 0) {
            var n: usize = 0;
            while (n < want and p.count > 0) : (n += 1) {
                const va: usize = @intCast(buva + n);
                if (userEntry(c, va) & 1 == 0) break;
                const ub: [*]u8 = @ptrFromInt(userPhys(c, va) + (va & 0xFFF));
                ub[0] = p.buf[p.tail];
                p.tail = (p.tail + 1) % p.buf.len;
                p.count -= 1;
            }
            asm volatile ("sti" ::: .{ .memory = true });
            if (n != 0) {
                pipe_reads += 1;
                wakePipe(idx); // space opened — prod any parked writer
                return @intCast(n);
            }
            if (userEntry(c, @intCast(buva)) & 1 == 0) return -14;
        } else if (p.wrefs == 0) {
            asm volatile ("sti" ::: .{ .memory = true });
            return 0; // last writer gone and drained — this read IS the EOS
        } else {
            c.wait_pipe = idx;
            pipe_rwaits += 1;
            kblock(.pipe); // wake = a byte or a writer left — recheck
        }
    }
}

fn pipeWriteEnd(c: *Child, idx: usize, buva: u64, want: u64) i64 {
    if (want == 0) return 0;
    const p = &pipes[idx];
    while (true) {
        asm volatile ("cli" ::: .{ .memory = true });
        if (p.rrefs == 0) {
            asm volatile ("sti" ::: .{ .memory = true });
            return -32; // EPIPE — no reader can ever drain this
        }
        if (p.count < p.buf.len) {
            var n: usize = 0;
            while (n < want and p.count < p.buf.len) : (n += 1) {
                const va: usize = @intCast(buva + n);
                if (userEntry(c, va) & 1 == 0) break;
                p.buf[p.head] = userByte(c, va);
                p.head = (p.head + 1) % p.buf.len;
                p.count += 1;
            }
            asm volatile ("sti" ::: .{ .memory = true });
            if (n != 0) {
                pipe_writes += 1;
                wakePipe(idx); // bytes landed — prod any parked reader
                return @intCast(n);
            }
            if (userEntry(c, @intCast(buva)) & 1 == 0) return -14;
        } else {
            c.wait_pipe = idx;
            pipe_wwaits += 1;
            kblock(.pipe); // wake = space freed or all readers gone
        }
    }
}

// Close one fd entry's endpoint. Ring outlives either end; both gone
// releases the slot. The surviving side wakes on its NEXT endpoint op —
// a parked peer is marked now and rechecks the new refcount itself.
fn pipeCloseEnd(idx: usize, kind: FdKind) void {
    const p = &pipes[idx];
    if (kind == .pipe_r) {
        if (p.rrefs > 0) p.rrefs -= 1;
        if (p.rrefs == 0) wakePipe(idx); // any parked writer sees EPIPE
    } else {
        if (p.wrefs > 0) p.wrefs -= 1;
        if (p.wrefs == 0) wakePipe(idx); // any parked reader sees EOS
    }
    if (p.rrefs == 0 and p.wrefs == 0) p.* = .{};
}

// Dying child's discharge: the exit arm's page reclaim can't see the fd
// table, so endpoint release lives here — called once, at death, before
// the slot becomes a zombie/dead.
fn releaseFds(c: *Child) void {
    for (0..c.fds.len) |i| {
        switch (c.fdkinds[i]) {
            .none => {},
            .fs => {
                if (c.fsv) |ops| _ = ops.close(ops.ctx, c.fds[i]);
            },
            .pipe_r, .pipe_w => pipeCloseEnd(@intCast(c.fds[i]), c.fdkinds[i]),
            .conin, .conout => {},
        }
        c.fds[i] = 0;
        c.fdkinds[i] = .none;
        c.fdverbs[i] = 0;
    }
}

// Spawn wiring and fork share this: project one of the SOURCE's fd
// entries into the destination's table. Pipes bump endpoint refs; fs
// entries go through the provider's dup op — the handle is refcounted
// provider-side (same offset, POSIX share semantics), so a close in one
// table can never free the handle out from under the other. false =
// the provider refused; the caller unwinds what it already cloned.
fn cloneFd(dst: *Child, dfd: usize, src: *Child, sfd: usize) bool {
    const kind = src.fdkinds[sfd];
    switch (kind) {
        .pipe_r => pipes[@intCast(src.fds[sfd])].rrefs += 1,
        .pipe_w => pipes[@intCast(src.fds[sfd])].wrefs += 1,
        .fs => {
            const ops = src.fsv orelse return false;
            const nh = ops.dup(ops.ctx, src.fds[sfd]);
            if (nh < 0) return false;
            dst.fdkinds[dfd] = kind;
            dst.fds[dfd] = @intCast(nh);
            dst.fdverbs[dfd] = src.fdverbs[sfd];
            return true;
        },
        else => {},
    }
    dst.fdkinds[dfd] = kind;
    dst.fds[dfd] = src.fds[sfd];
    dst.fdverbs[dfd] = src.fdverbs[sfd]; // the verbs ride the projection
    return true;
}

// nr 22 — pipe(fds[2]): mint a ring, write the two NEW fd numbers into
// the caller's two-int array. Refuses EMFILE on a full table or pool.
fn childPipe(c: *Child, pva: u64) i64 {
    var slots: [2]usize = undefined;
    var sn: usize = 0;
    for (0..c.fds.len) |i| {
        if (c.fdkinds[i] == .none) {
            slots[sn] = i;
            sn += 1;
            if (sn == 2) break;
        }
    }
    if (sn < 2) return -24; // EMFILE
    const pi = pipeCreate() orelse return -24;
    var out: [8]u8 = undefined;
    for (0..2) |i| {
        const v: u32 = @intCast(slots[i]);
        std.mem.writeInt(u32, out[i * 4 ..][0..4], v, .little);
    }
    if (copyToUser(c, @intCast(pva), &out) < 8) {
        pipes[pi] = .{};
        return -14;
    }
    c.fdkinds[slots[0]] = .pipe_r;
    c.fds[slots[0]] = pi;
    c.fdverbs[slots[0]] = V_READ;
    c.fdkinds[slots[1]] = .pipe_w;
    c.fds[slots[1]] = pi;
    c.fdverbs[slots[1]] = V_WRITE;
    return 0;
}

// nr 61 — wait(pid, status): pid is the pid-domain id spawn_start/fork
// handed back (slot+1; slots are internal, 0 is never a pid). -1 waits
// for ANY zombie. Reaping marks the slot .dead: the status is claimed
// once and a reused slot can never serve it twice.
const ANY_PID: usize = ~@as(usize, 0);
fn childWait(c: *Child, pid: i64, stva: u64) i64 {
    while (true) {
        asm volatile ("cli" ::: .{ .memory = true });
        var slot: ?usize = null;
        var live = false;
        if (pid == -1) {
            for (0..nchildren) |i| {
                const st = children[i].state;
                if (st == .zombie and slot == null) slot = i;
                if (st == .runnable or st == .blocked) live = true;
            }
        } else {
            if (pid < 1 or pid > MAXCHILDREN) {
                asm volatile ("sti" ::: .{ .memory = true });
                return -10; // ECHILD — no such pid
            }
            const s: usize = @intCast(pid - 1);
            const st = children[s].state;
            if (st == .zombie) slot = s;
            live = st == .runnable or st == .blocked;
        }
        if (slot) |g| {
            const status = children[g].exit_status;
            children[g].state = .dead;
            children[g].waitable = false;
            asm volatile ("sti" ::: .{ .memory = true });
            if (stva != 0) {
                // the wait4 status word is ENCODED — exit code in the
                // high byte (WIFEXITED tests the low 7 bits for signals,
                // WEXITSTATUS reads the code back out). A raw code would
                // misreport a clean exit as a signal death.
                var stb: [4]u8 = undefined;
                const sv: u32 = @truncate(@as(u64, @bitCast(status)) << 8);
                stb[0] = @truncate(sv);
                stb[1] = @truncate(sv >> 8);
                stb[2] = @truncate(sv >> 16);
                stb[3] = @truncate(sv >> 24);
                if (copyToUser(c, @intCast(stva), &stb) < 4) return -14;
            }
            return @intCast(g + 1); // pid domain — slots are internal
        }
        if (!live) {
            asm volatile ("sti" ::: .{ .memory = true });
            return -10; // ECHILD — nobody left that could still die
        }
        c.wait_pid = if (pid == -1) ANY_PID else @intCast(pid - 1); // slot
        kblock(.exit); // a death mark wakes us; the loop re-questions
    }
}

// Spawn builder shared by nr57 (fused spawn+wait) and nr58 (detached).
// Builds tables, loads through the caller's fs view, primes the frame and
// the fd projection — stdio defaults to conin/conout entries; in_src/
// out_src (r8/r9 on nr58) override fd0/fd1 by CLONING caller entries, so
// `a | b` is a pipe end projected into each child's table, not an inherit-
// all that could never express the swap. Returns the slot or -errno.
const SPAWN_NO_FD: u64 = ~@as(u64, 0);
fn spawnBuild(c: *Child, f: *TrapFrame, waitable: bool, in_src: u64, out_src: u64) i64 {
    if (c.fsv == null) return -38; // ENOSYS — no fs view, nothing to exec
    var pb: [256]u8 = undefined;
    const path = userPath(c, @intCast(f.rdi), &pb) orelse return -14;
    // The blob IS the bag's wire form: rdx/r10 name a bounded 'KGRB'
    // section stream in OUR space — argv rides section 1 (NUL-separated,
    // unchanged), grant records section 2, env lands as 3. One bounded
    // copy, no pointer-array chase; a present-but-malformed stream is
    // EINVAL, an unknown tag is EINVAL — never a silent skip. Absent
    // stream defaults argv[0] to the path (POSIX's own convention).
    const ABLOB_MAX = 512;
    var blob: [ABLOB_MAX]u8 = undefined;
    var ablob: [ABLOB_MAX]u8 = undefined;
    var ablen: usize = 0;
    var grecs: [MAXGRANTS]Grant = undefined;
    var ngrecs: usize = 0;
    if (f.rdx != 0 and f.r10 != 0) {
        const blen: usize = @intCast(f.r10);
        if (blen > ABLOB_MAX) return -22; // EINVAL — block exceeds the cap
        if (copyFromUser(c, @intCast(f.rdx), blob[0..blen]) < blen) return -14; // EFAULT
        if (blen < 6 or readU32(&blob, 0) != SECT_MAGIC) return -22; // not a section stream
        var pos: usize = 6;
        var s: usize = 0;
        const nsec = readU16(&blob, 4);
        while (s < nsec) : (s += 1) {
            if (pos + 4 > blen) return -22;
            const tag = readU16(&blob, pos);
            const slen = readU16(&blob, pos + 2);
            pos += 4;
            if (pos + slen > blen) return -22;
            switch (tag) {
                TAG_ARGV => {
                    if (slen > ablob.len) return -7;
                    @memcpy(ablob[0..slen], blob[pos .. pos + slen]);
                    ablen = slen;
                },
                TAG_GRANT => {
                    if (slen % 16 != 0) return -22;
                    var gi: usize = 0;
                    while (gi < slen) : (gi += 16) {
                        const g = Grant{
                            .obj = readU64(&blob, pos + gi),
                            .verbs = blob[pos + gi + 8],
                            .cap = blob[pos + gi + 9],
                            .pad = .{0} ** 6,
                        };
                        if (g.cap >= 64) return -22;
                        if (ngrecs == MAXGRANTS) return -7; // E2BIG — bag full
                        // attenuation at marshal time: the grant must be
                        // covered by the CALLER's bag or the whole spawn
                        // refuses — amplification is never minted.
                        if (!parentCovers(c, g)) {
                            say("SEAM REFUSE grant cap=");
                            puthex(g.cap);
                            say(" obj=");
                            puthex(g.obj);
                            say(" — exceeds parent's bag\n");
                            return -13; // EACCES
                        }
                        grecs[ngrecs] = g;
                        ngrecs += 1;
                    }
                },
                else => return -22, // unknown section — refuse by tag
            }
            pos += slen;
        }
        if (pos != blen) return -22;
    } else {
        if (path.len + 1 > ABLOB_MAX) return -7;
        @memcpy(ablob[0..path.len], path);
        ablob[path.len] = 0;
        ablen = path.len + 1;
    }
    if (ablen > 0) { // argv section or the default — bound the vector
        var bi: usize = 0;
        var na: usize = 0;
        while (bi < ablen and na < MAXARGS) {
            na += 1;
            while (bi < ablen and ablob[bi] != 0) bi += 1;
            bi += 1;
        }
        if (bi < ablen) return -7; // E2BIG — argv vector past MAXARGS
    } else {
        if (path.len + 1 > ABLOB_MAX) return -7;
        @memcpy(ablob[0..path.len], path);
        ablob[path.len] = 0;
        ablen = path.len + 1;
    }
    // a free slot: dead slots were reaped and are reusable; empty slots
    // extend the roster. A .zombie holds its status until claimed — it
    // is NOT free for reuse.
    var slot: ?usize = null;
    for (0..MAXCHILDREN) |i| {
        const s = children[i].state;
        if (s == .empty or s == .dead) { slot = i; break; }
    }
    const g = slot orelse return -11; // EAGAIN — roster full
    const nc = &children[g];
    nc.* = .{};
    if (!buildTables(nc)) return -12; // ENOMEM
    nc.fsv = c.fsv; // spawned inside the same view the caller names paths through
    // stdio is a projection too: conin/conout entries by default, the
    // caller's in_src/out_src entries cloned in when wiring is asked for.
    nc.fdkinds[0] = .conin;
    nc.fdkinds[1] = .conout;
    nc.fdkinds[2] = .conout;
    nc.fdverbs[0] = V_READ;
    nc.fdverbs[1] = V_WRITE;
    nc.fdverbs[2] = V_WRITE;
    if (in_src != SPAWN_NO_FD) {
        if (in_src >= c.fds.len or c.fdkinds[@intCast(in_src)] == .none) {
            _ = freeChild(nc);
            return -9; // EBADF — wiring names a dead slot
        }
        if (!cloneFd(nc, 0, c, @intCast(in_src))) {
            _ = freeChild(nc);
            return -12; // ENOMEM — provider refused the dup
        }
    }
    if (out_src != SPAWN_NO_FD) {
        if (out_src >= c.fds.len or c.fdkinds[@intCast(out_src)] == .none) {
            _ = freeChild(nc);
            return -9;
        }
        if (!cloneFd(nc, 1, c, @intCast(out_src))) {
            _ = freeChild(nc);
            return -12;
        }
    }
    var ipath: [256]u8 = undefined;
    var ilen: usize = 0;
    const info = loadElfViaFs(nc, path, USER_VA_BASE, &ipath, &ilen) orelse {
        releaseFds(nc);
        _ = freeChild(nc);
        return -2; // ENOENT — the view refused the path
    };
    var entry = info.entry;
    var at_base: u64 = 0;
    if (ilen > 0) { // PT_INTERP — the loader streams through the same view
        const iname = std.mem.sliceTo(ipath[0..ilen], 0);
        const iinfo = loadElfViaFs(nc, iname, INTERP_BASE, null, null) orelse {
            releaseFds(nc);
            _ = freeChild(nc);
            return -2;
        };
        at_base = INTERP_BASE;
        entry = iinfo.entry;
    }
    if (g >= nchildren) nchildren = g + 1;
    nc.rights = f.rsi & c.rights; // a spawned bag can only narrow
    // the mask is the class side; the sectioned blob carried the object
    // side — already attenuated against the caller's bag at parse time.
    nc.ngrants = @intCast(ngrecs);
    for (grecs[0..ngrecs], 0..) |gr, i| nc.grants[i] = gr;
    nc.waitable = waitable;
    nc.frame = std.mem.zeroes(UserFrame);
    nc.frame.rip = entry;
    nc.frame.cs = 0x23;
    nc.frame.rflags = 0x202;
    nc.frame.ss = 0x1B;
    nc.frame.rsp = buildStack(nc, info, at_base, ablob[0..ablen]) orelse {
        releaseFds(nc);
        _ = freeChild(nc);
        return -12;
    };
    nc.brk_base = info.brk_base;
    nc.brk = info.brk_base;
    nc.mmap_top = MMAP_BASE;
    nc.state = .runnable;
    return @intCast(g);
}

// nr 512 — koru spawn. It USED to squat musl's nr57 fork slot; musl
// _Fork really does syscall(57) with zero args, so the koru ABI moved
// to 512+ (canonNr folds 512/513 onto caps 57/58 — bags unchanged).
// The child starts from a *path in the caller's fs view* and the caller
// parks on it until exit — the spawned child's status IS the return
// value (a blocking spawn, not fork+exec+wait4). nr513 (spawn_start)
// is the detached twin: same builder, same args plus r8/r9 fd wiring,
// returns the pid at once; the child is .waitable — its status parks in
// a .zombie until nr61 wait claims it. Both children of a pipeline must
// coexist; the fused shape can never express that.
fn childSpawn(c: *Child, f: *TrapFrame) i64 {
    const r = spawnBuild(c, f, false, SPAWN_NO_FD, SPAWN_NO_FD);
    if (r < 0) return r;
    const g: usize = @intCast(r);
    // park on the child's exit: each kblock hands the roster to whoever
    // is runnable (the grandchild included); the exit arm writes our
    // spawn_ret before marking us runnable, so the status we return IS
    // the child's exit code — the syscall completes itself.
    c.wait_pid = g;
    while (true) {
        asm volatile ("cli" ::: .{ .memory = true });
        const st = children[g].state;
        if (st == .dead or st == .zombie) {
            asm volatile ("sti" ::: .{ .memory = true });
            break;
        }
        kblock(.exit);
    }
    c.wait_pid = 0;
    return c.spawn_ret;
}

// Clone the caller's whole user space into `dst`: walk the parent's upd
// tree — every present pde gets its own pt frame, every present pte a
// fresh page carrying the parent's bytes AND flag bits verbatim (a
// PROT_NONE/read-only leaf stays that way in the child — the copy is
// honest, not all-writable like mapUserPage's loader pages). Eager, not
// CoW: a fault-driven shared-page copy is its own rung; today's honest
// measure is fork_pages.
fn cloneUserSpace(dst: *Child, src: *Child) bool {
    const supd: *const [512]u64 = @ptrFromInt(src.upd);
    const dupd: *[512]u64 = @ptrFromInt(dst.upd);
    for (supd, 0..) |pde, i| {
        if (pde & 1 == 0) continue;
        const spt: *const [512]u64 = @ptrFromInt(@as(usize, @intCast(pde & ~@as(u64, 0xFFF))));
        const dpt: *[512]u64 = @ptrCast(allocPage() orelse return false);
        // flags ride verbatim — including NX (bit 63), which no leaf sets
        // today but a copied entry must never silently widen.
        const PDE_FLAGS: u64 = 0x8000_0000_0000_0FFF;
        dupd[i] = @as(u64, @intFromPtr(dpt)) | (pde & PDE_FLAGS);
        for (spt, 0..) |e, j| {
            if (e & 1 == 0) continue;
            const np = allocPage() orelse return false;
            const old: *const [4096]u8 = @ptrFromInt(@as(usize, @intCast(e & ~@as(u64, 0xFFF))));
            @memcpy(np, old);
            dpt[j] = @as(u64, @intFromPtr(np)) | (e & PDE_FLAGS);
            fork_pages += 1;
        }
    }
    return true;
}

// nr 57 — fork(): a real address-space copy at the POSIX ABI tier. This
// does NOT relax the koru spawn contract's F2 — ambient copy stays
// refused there; fork is the musl-personality verb, and the copy it
// performs is explicit work in the aspace layer, metered in fork_pages.
// The child's frame is synthesized as "just returned from this syscall
// with rax=0": it resumes on the instruction after `syscall`, in its
// own copy of the stack, with its own page tables. Entry path matters:
// the syscall gate keeps user rip/rflags in the frame's rcx/r11 slots
// and the user rsp in the courier; int80's hw tail sits 120B deeper.
fn childFork(c: *Child, f: *TrapFrame) i64 {
    var slot: ?usize = null;
    for (0..MAXCHILDREN) |i| {
        const s = children[i].state;
        if (s == .empty or s == .dead) { slot = i; break; }
    }
    const g = slot orelse return -11; // EAGAIN — roster full
    const nc = &children[g];
    nc.* = .{};
    if (!buildTables(nc)) return -12; // ENOMEM
    if (!cloneUserSpace(nc, c)) {
        _ = freeChild(nc);
        return -12;
    }
    nc.fsv = c.fsv;
    // dup the whole fd projection — fs handles go through the provider's
    // dup (refcounted share, one offset), pipe ends bump ring refs.
    for (0..c.fds.len) |i| {
        if (c.fdkinds[i] == .none) continue;
        if (!cloneFd(nc, i, c, i)) {
            releaseFds(nc);
            _ = freeChild(nc);
            return -12;
        }
    }
    if (g >= nchildren) nchildren = g + 1;
    nc.rights = c.rights; // fork inherits the bag — same security domain
    nc.grants = c.grants;
    nc.ngrants = c.ngrants;
    nc.waitable = true;   // the status holds in a zombie for nr61 wait
    nc.fsbase = c.fsbase;
    nc.brk = c.brk;
    nc.brk_base = c.brk_base;
    nc.mmap_top = c.mmap_top;
    nc.ursp = c.ursp;
    const fr: *const [15]u64 = @ptrCast(f);
    for (0..15) |k| nc.frame.gp[k] = fr[k];
    nc.frame.gp[0] = 0; // the child sees fork()==0
    if (child_entry == 1) {
        nc.frame.rip = f.rcx;
        nc.frame.cs = 0x23;
        nc.frame.rflags = f.r11;
        nc.frame.rsp = c.ursp;
        nc.frame.ss = 0x1B;
    } else {
        const hw: *const [5]u64 = @ptrFromInt(@intFromPtr(f) + 15 * 8);
        nc.frame.rip = hw[0];
        nc.frame.cs = hw[1];
        nc.frame.rflags = hw[2];
        nc.frame.rsp = hw[3];
        nc.frame.ss = hw[4];
    }
    nc.state = .runnable;
    forks += 1;
    return @intCast(g + 1); // pid domain — slot+1; 0 means "the child"
}

// nr 56 — clone: this rung serves only the fork-shaped flag set
// (SIGCHLD alone, flags==0x11). CLONE_VM/VFORK/THREAD/PARENT are each
// their own axis — refused by name, never silently forked.
fn childClone(c: *Child, f: *TrapFrame) i64 {
    if (f.rdi == 0x11) return childFork(c, f);
    say("SEAM REFUSE clone flags=");
    puthex(f.rdi);
    say(" (not the fork shape)\n");
    return -38; // ENOSYS
}

export fn ring3_trap(f: *TrapFrame) callconv(.c) void {
    // child_ursp is written per-ENTRY by the syscall gate — a trap that
    // parks mid-call outlives it (other children's syscalls clobber it),
    // so the running child's rsp lives in its slot. The defer publishes
    // it back right before any return path reaches the epilogue, which
    // reloads it for sysret — the global is a courier, not the home.
    const me = &children[cur_child];
    me.ursp = child_ursp;
    defer child_ursp = me.ursp;
    // bag check before dispatch: an nr not granted by the armed child's
    // bag is a capability refusal, loud on serial AND visible to the
    // child as -EACCES — not a silent ENOSYS. Bits name capability
    // CLASSES (the mask is the class projection); object grants light
    // their class for dispatch and the arm checks the object side.
    const cnr = canonNr(f.rax);
    if (cnr >= 64 or !bagAllows(me, cnr)) {
        say("SEAM REFUSE nr=");
        puthex(f.rax);
        say(" (not in child bag)\n");
        f.rax = @bitCast(@as(i64, -13));
        return;
    }
    const c = &children[cur_child];
    switch (f.rax) {
        1 => { // write(fd, buf, len) — kind dispatch: conout sinks to
               // serial, pipe_w feeds the ring (blocks on full, EPIPE on
               // dead readers); an fs view is read-only — EROFS, not a
               // silent drop.
            if (f.rdi >= c.fds.len) {
                f.rax = @bitCast(@as(i64, -9));
            } else {
                const fdi: usize = @intCast(f.rdi);
                switch (c.fdkinds[fdi]) {
                    .conout => {
                        if (f.rdx != 0) {
                            if (f.rsi == 0) {
                                f.rax = @bitCast(@as(i64, -14)); // EFAULT
                                return;
                            }
                            const buf: [*]const u8 = @ptrFromInt(@as(usize, @intCast(f.rsi)));
                            var i: usize = 0;
                            while (i < f.rdx) : (i += 1) serPut(buf[i]);
                        }
                        f.rax = f.rdx;
                    },
                    .pipe_w => f.rax = @bitCast(pipeWriteEnd(c, @intCast(c.fds[fdi]), f.rsi, f.rdx)),
                    // The fd is the grant: a write verb was minted at
                    // open or this projection never carried one — EBADF,
                    // the POSIX refusal for a bad-mode write.
                    .fs => f.rax = @bitCast(if (c.fdverbs[fdi] & V_WRITE != 0)
                        childWrite(c, fdi, f.rsi, f.rdx) else -9),
                    else => f.rax = @bitCast(@as(i64, -9)),
                }
            }
        },
        20 => { // writev(fd, iov, iovcnt) — kind dispatch like write(1):
                // conout sinks each iov to serial, pipe_w feeds the ring
                // per iov, .fs writes through the view when the fd's verb
                // allows. musl's stdio is a writev caller — this arm is
                // why a FILE*'s bytes reach the file, not the console.
            if (f.rdi >= c.fds.len) {
                f.rax = @bitCast(@as(i64, -9));
            } else {
                const fdi: usize = @intCast(f.rdi);
                const iov: [*]const u64 = @ptrFromInt(@as(usize, @intCast(f.rsi)));
                var total: i64 = 0;
                var i: usize = 0;
                var fail: i64 = 0;
                while (i < f.rdx) : (i += 1) {
                    const base: usize = @intCast(iov[i * 2]);
                    const len: usize = @intCast(iov[i * 2 + 1]);
                    if (len == 0) continue; // libcs send trailing {NULL,0} iovs
                    if (base == 0) { fail = -14; break; }
                    switch (c.fdkinds[fdi]) {
                        .conout => {
                            const buf: [*]const u8 = @ptrFromInt(base);
                            var n: usize = 0;
                            while (n < len) : (n += 1) serPut(buf[n]);
                            total += @intCast(len);
                        },
                        .fs => {
                            if (c.fdverbs[fdi] & V_WRITE == 0) { fail = -9; break; }
                            const n = childWrite(c, fdi, @intCast(base), @intCast(len));
                            if (n < 0) { fail = n; break; }
                            total += n;
                            if (n < len) break; // short write — stop
                        },
                        .pipe_w => {
                            const n = pipeWriteEnd(c, @intCast(c.fds[fdi]), @intCast(base), @intCast(len));
                            if (n < 0) { fail = n; break; }
                            total += n;
                            if (n < len) break;
                        },
                        else => { fail = -9; break; },
                    }
                }
                f.rax = @bitCast(if (total > 0) total else if (fail != 0) fail else @as(i64, 0));
            }
        },
        2, 257 => { // open(path,flags) / openat(dirfd,path,flags)
            // Scoped fs view: paths resolve inside the fs the child was
            // spawned from — nothing else exists for it to mean.
            if (f.rax == 257 and f.rdi != @as(u64, @bitCast(@as(i64, -100)))) {
                f.rax = @bitCast(@as(i64, -9)); // EBADF — only AT_FDCWD has meaning here
            } else {
                const pva: usize = if (f.rax == 2) @intCast(f.rdi) else @intCast(f.rsi);
                const fl = if (f.rax == 2) f.rsi else f.rdx;
                f.rax = @bitCast(childOpen(c, pva, fl));
            }
        },
        85 => { // creat(path) ≡ open(path, O_WRONLY|O_CREAT|O_TRUNC)
            f.rax = @bitCast(childOpen(c, @intCast(f.rdi), 0o1101));
        },
        514 => { // openobj(key, flags) — koru's object-axis open; the
                 // key is the name, no path ever resolves.
            f.rax = @bitCast(childOpenObj(c, f.rdi, f.rsi));
        },
        82, 264, 316 => { // rename / renameat / renameat2 — the directory
                          // entries move; the inode (the identity) does
                          // not. renameat2 flags must be 0 (no exchange/
                          // noreplace/whiteout verbs exist yet).
            if (f.rax == 316 and f.r8 != 0) {
                f.rax = @bitCast(@as(i64, -38)); // ENOSYS — no renameat2 verbs
            } else if (f.rax != 82 and
                       (f.rdi != @as(u64, @bitCast(@as(i64, -100))) or
                        f.rdx != @as(u64, @bitCast(@as(i64, -100))))) {
                f.rax = @bitCast(@as(i64, -9)); // only AT_FDCWD has meaning
            } else {
                const ova: usize = if (f.rax == 82) @intCast(f.rdi) else @intCast(f.rsi);
                const nva: usize = if (f.rax == 82) @intCast(f.rsi) else @intCast(f.r10);
                f.rax = @bitCast(childRename(c, ova, nva));
            }
        },
        87, 263 => { // unlink / unlinkat — removes a name; AT_REMOVEDIR
                     // asks for rmdir, which this rung doesn't serve.
            if (f.rax == 263 and
                (f.rdi != @as(u64, @bitCast(@as(i64, -100))) or (f.rdx & 0x200) != 0)) {
                f.rax = @bitCast(if ((f.rdx & 0x200) != 0) @as(i64, -38) else -9);
            } else {
                const pva: usize = if (f.rax == 87) @intCast(f.rdi) else @intCast(f.rsi);
                f.rax = @bitCast(childUnlink(c, pva));
            }
        },
        0 => { // read(fd, buf, len) — kind dispatch: conin returns bytes
               // or parks; fs handles ride the view; pipe_r drains the
               // ring or parks on empty (EOS when writers are gone).
            if (f.rdi >= c.fds.len) {
                f.rax = @bitCast(@as(i64, -9));
            } else {
                const fdi: usize = @intCast(f.rdi);
                f.rax = @bitCast(switch (c.fdkinds[fdi]) {
                    .conin => coninRead(c, f),
                    .fs => if (c.fdverbs[fdi] & V_READ != 0)
                        childRead(c, f.rdi, f.rsi, f.rdx) else -9,
                    .pipe_r => pipeReadEnd(c, @intCast(c.fds[fdi]), f.rsi, f.rdx),
                    else => @as(i64, -9),
                });
            }
        },
        22 => { // pipe(fds[2]) — mints a ring; endpoints land as pipe_r/
                // pipe_w entries in the caller's projection.
            f.rax = @bitCast(childPipe(c, f.rdi));
        },
        56 => { // clone(flags,...) — only the fork shape (SIGCHLD) this rung
            f.rax = @bitCast(childClone(c, f));
        },
        57 => { // fork() — real POSIX: copy the caller's space, child gets 0
            f.rax = @bitCast(childFork(c, f));
        },
        512 => { // koru spawn(path, rights, blob, blen) — fused spawn+wait,
                 // out of musl's namespace; canonNr folds it to cap 57.
            f.rax = @bitCast(childSpawn(c, f));
        },
        513 => { // koru spawn_start — detached twin, returns the pid; r8/r9
                 // name the caller's fd entries to project into fd0/fd1.
            const r = spawnBuild(c, f, true, f.r8, f.r9);
            f.rax = @bitCast(if (r < 0) r else r + 1); // slot → pid domain
        },
        61 => { // wait(pid, status) — pid is a slot nid, -1 any zombie
            f.rax = @bitCast(childWait(c, @bitCast(f.rdi), f.rsi));
        },
        3 => { // close(fd) — discharge whatever the slot projects; a
               // conin/conout close just detaches.
            if (f.rdi < c.fds.len) {
                const fd: usize = @intCast(f.rdi);
                const had = c.fdkinds[fd];
                c.fdverbs[fd] = 0;
                switch (had) {
                    .none => f.rax = @bitCast(@as(i64, -9)),
                    .conin, .conout => {
                        c.fdkinds[fd] = .none;
                        f.rax = 0;
                    },
                    .fs => {
                        if (c.fsv) |ops| _ = ops.close(ops.ctx, c.fds[fd]);
                        c.fds[fd] = 0;
                        c.fdkinds[fd] = .none;
                        f.rax = 0;
                    },
                    .pipe_r, .pipe_w => {
                        pipeCloseEnd(@intCast(c.fds[fd]), had);
                        c.fds[fd] = 0;
                        c.fdkinds[fd] = .none;
                        f.rax = 0;
                    },
                }
            } else {
                f.rax = @bitCast(@as(i64, -9));
            }
        },
        8 => { // lseek(fd, off, whence)
            f.rax = @bitCast(childSeek(c, f.rdi, @bitCast(f.rsi), @intCast(f.rdx)));
        },
        5 => { // fstat(fd, st) — 144B linux stat, statx is a different nr
            f.rax = @bitCast(childFstat(c, f.rdi, f.rsi));
        },
        17 => { // pread64(fd, buf, len, off) — read without moving pos
            f.rax = @bitCast(childPread(c, f.rdi, f.rsi, f.rdx, f.r10));
        },
        14 => { // rt_sigprocmask — no signals exist to mask; musl's
                // _Fork calls this on both sides. A no-op success, same
                // class as fcntl's flagless handles.
            f.rax = 0;
        },
        39 => { // getpid — the pid domain is slot+1 (0 can never answer
                // "am I the child" ambiguously)
            f.rax = @intCast(cur_child + 1);
        },
        72 => { // fcntl(fd, cmd, arg) — our fds are opaque handles with no
            // flag state; the flags a libc sets (CLOEXEC, NONBLOCK) have no
            // consumer in this child, so the honest answer is success.
            f.rax = 0;
        },
        63 => { // uname(buf) — the kernel's own identity, honestly named:
            // a real GNU uname prints what we are, not a Linux costume.
            var uts: [390]u8 = std.mem.zeroes([390]u8);
            const fields = [_][]const u8{ "koru-os", "child0", "0.1", "native", "x86_64", "" };
            for (fields, 0..) |s, i| @memcpy(uts[i * 65 ..][0..s.len], s);
            const n = copyToUser(c, @intCast(f.rdi), &uts);
            f.rax = if (n < 390) @bitCast(@as(i64, -14)) else 0;
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
        9 => { // mmap(addr,len,prot,flags,fd,off)
            // anon-private: bump-alloc from the mmap arena. file-backed:
            // MAP_PRIVATE only (shared writes would need a write-through
            // the read-only view can't make), fd must be a live fs-view
            // handle, offset page-aligned — fill is read_at straight into
            // the mapped pages; bytes past EOF stay zero (a mapped tail
            // SIGBUSes on real linux; zeroing is the honest v1).
            const len: usize = @intCast(f.rsi);
            if (len == 0) {
                f.rax = @bitCast(@as(i64, -22));
            } else if (f.r10 & 0x20 != 0) { // MAP_ANONYMOUS
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
            } else {
                f.rax = @bitCast(childMmapFile(c, f.rdi, len, f.rdx, f.r10, f.r8, f.r9));
            }
        },
        10 => { // mprotect(addr,len,prot) — the W bit is real; PROT_EXEC
            // is advisory (no NXE): text/relro RO transitions ld.so needs
            // land exactly through setUserWritable.
            const base: usize = @intCast(f.rdi);
            const len: usize = @intCast(f.rsi);
            setUserWritable(c, base, len, f.rdx & 2 != 0);
            f.rax = 0;
        },
        11 => { // munmap(addr,len) — frames go back to the pmm, not to a
            // deferred freelist: the child paid them, the child gets them back.
            var p: usize = @intCast(f.rdi & ~@as(u64, 0xFFF));
            const end: usize = @intCast(f.rdi + f.rsi);
            while (p < end) : (p += 0x1000) {
                const e = userEntry(c, p);
                if (e & 1 != 0) {
                    _ = pmm.free(e & ~@as(u64, 0xFFF));
                    const upd: *[512]u64 = @ptrFromInt(c.upd);
                    const pd_i = (p - USER_VA_BASE) >> 21;
                    const pt: *[512]u64 = @ptrFromInt(@as(usize, @intCast(upd[pd_i] & ~@as(u64, 0xFFF))));
                    pt[(p >> 12) & 0x1FF] = 0;
                }
            }
            f.rax = 0;
        },
        158 => { // arch_prctl(code, addr) — the TLS seam: FS base per child
            if (f.rdi == 0x1002) { // ARCH_SET_FS
                c.fsbase = f.rsi;
                // The MSR must hold the new base BEFORE sysret — the
                // child's very next instruction may read %fs:0. Only
                // resumeChild reloaded it before; musl survived on a
                // lucky preemption tick, fscat didn't.
                wrmsr(0xC0000100, c.fsbase);
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
            if (f.rsi != 0) { // len 0 legal even with a NULL buf
                if (f.rdi == 0) {
                    f.rax = @bitCast(@as(i64, -14)); // EFAULT
                    return;
                }
                const buf: [*]u8 = @ptrFromInt(@as(usize, @intCast(f.rdi)));
                var s: u64 = rdtsc() ^ f.rsi;
                var i: usize = 0;
                while (i < f.rsi) : (i += 1) {
                    s ^= s << 13; s ^= s >> 7; s ^= s << 17;
                    buf[i] = @truncate(s);
                }
            }
            f.rax = f.rsi;
        },
        60, 231 => { // exit/exit_group(code) — child dies, frames go back
            last_exit = f.rdi;
            const dead_slot = cur_child;
            // The fd projection dies with the child — endpoint refs drop
            // here, which is what wakes a peer blocked on this pipe.
            releaseFds(&children[dead_slot]);
            // Wake spawn/wait-waiters with the status already in hand: a
            // parent's loop breaks on observing this slot .dead/.zombie,
            // then reads its OWN spawn_ret — the value can't be clobbered
            // by the dead slot's reuse because it lives in the waiter.
            // ANY_PID is nr61's wait-any mark.
            for (0..nchildren) |i| {
                const p = &children[i];
                if (p.state == .blocked and p.wait_kind == .exit and
                    (p.wait_pid == dead_slot or p.wait_pid == ANY_PID)) {
                    p.spawn_ret = @bitCast(last_exit);
                    p.state = .runnable;
                }
            }
            const dead = &children[cur_child];
            dead.exit_status = @bitCast(last_exit);
            // .waitable (nr513/fork) parks the status in a .zombie for
            // wait to claim; a fused nr512 child has no claimant — .dead.
            dead.state = if (dead.waitable) .zombie else .dead;
            const nf = freeChild(dead);
            say("pmm: reap freed=");
            puthex(nf);
            say("\n");
            if (anyLive()) schedLoop(); // runnable or parked — keep the epoch
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
        else => {
            say("SEAM ENOSYS nr=");
            puthex(f.rax);
            say("\n");
            f.rax = @bitCast(@as(i64, -38));
        },
    }
}

// First runnable child after `cur` (wraps); null when nothing is
// runnable — dead, empty, or parked. Distinct from anyLive: a parked
// child is not dead.
fn nextRunnable() ?usize {
    for (0..nchildren) |k| {
        const j = (cur_child + 1 + k) % nchildren;
        if (children[j].state == .runnable) return j;
    }
    return null;
}

// Any child still in the epoch — runnable or parked. The roster drains
// for the spawn caller only when this goes false.
fn anyLive() bool {
    for (0..nchildren) |i| {
        const s = children[i].state;
        if (s == .runnable or s == .blocked) return true;
    }
    return false;
}

fn wrmsr(msr: u32, v: u64) void {
    asm volatile ("wrmsr"
        :
        : [c] "{ecx}" (msr), [a] "{eax}" (@as(u32, @truncate(v))), [d] "{edx}" (@as(u32, @truncate(v >> 32))));
}

// Arm child `n` as the running context: roster cursor, its rights bag on
// the seam, both ring-0 entry stacks (syscall rsp0_val and TSS.rsp0)
// repointed at its own kstack, and its TLS base in FS_BASE. Every
// transition — frame resume, kernel-context switch, tick rotation —
// goes through here so a child never traps on a bystander's stack.
fn armChild(n: usize) void {
    const c = &children[n];
    cur_child = n;
    const ktop = kstackTop(n);
    rsp0_val = ktop;
    @as(*u64, @ptrCast(@alignCast(&tss[4]))).* = ktop;
    wrmsr(0xC0000100, c.fsbase); // FS_BASE — the child's TLS home
}

// Resume child `nxt` at user level: rsp -> its saved UserFrame (a field
// of the slot, not any stack), CR3 -> its space, then the shared
// pop+iretq tail. Never returns — the current context (kernel stack or
// a dead child's syscall frame) is abandoned by construction.
fn resumeChild(nxt: usize) noreturn {
    const c = &children[nxt];
    armChild(nxt);
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

// Run child `n` however it waits to be run: a live kernel continuation
// (kctx != 0 — it blocked mid-call) gets its pushed block popped and
// returned into; anything else is a saved user frame.
fn switchInto(n: usize) noreturn {
    const c = &children[n];
    sched_switches += 1;
    const via_tick = tick_armed;
    tick_armed = false;
    if (c.kctx != 0) {
        kctx_resumes += 1;
        if (via_tick) tick_kctx += 1;
        const k = c.kctx;
        c.kctx = 0;
        armChild(n);
        asm volatile (
            \\ mov %[cr3], %%rax
            \\ mov %%rax, %%cr3
            \\ mov %[k], %%rsp
            \\ pop %%r15
            \\ pop %%r14
            \\ pop %%r13
            \\ pop %%r12
            \\ pop %%rbx
            \\ pop %%rbp
            \\ ret
            :
            : [k] "r" (k),
              [cr3] "r" (c.pml4)
            : .{ .memory = true });
        unreachable;
    }
    resumeChild(n);
}

// The scheduler loop on whatever kernel stack it was entered on: pick a
// runnable child and switchInto it, or hlt (IF already 1) to the next
// IRQ. Reached from ksched (a child just blocked) and from the exit
// arm's not-drained tail. A roster with nothing runnable but blocked
// children halts here — that is the epoch holding open, correctly.
fn schedLoop() noreturn {
    asm volatile ("sti" ::: .{ .memory = true });
    while (true) {
        if (nextRunnable()) |n| switchInto(n);
        asm volatile ("hlt" ::: .{ .memory = true });
    }
}

// kblock's continuation point: koru_kblock (asm) pushed the callee-saved
// block on this child's kstack and handed us its rsp; record it and
// enter the scheduler. The mark (state/wait_kind) happened under cli in
// the caller — schedLoop's sti publishes both atomically wrt wakes.
export fn ksched(saved: u64) callconv(.c) noreturn {
    children[cur_child].kctx = saved;
    schedLoop();
}

// Park the running child mid-call on `kind`: the caller has already
// rechecked its wait condition under cli; we mark, save kernel context,
// and schedule. Returns on this same stack when a waker flips us
// runnable — with IF=1 and the caller-saved set dead, like any call.
// Contract: call with IF=0 so the mark can't race the wait condition.
fn kblock(kind: WaitKind) void {
    const c = &children[cur_child];
    c.wait_kind = kind;
    c.state = .blocked;
    koru_kblock();
    c.wait_kind = .none;
}

// Wake every child blocked on `kind` — the resumed continuation
// re-decides, so waking is always just a mark, never surgery.
fn wakeKind(kind: WaitKind) void {
    if (!sched_active) return;
    for (0..nchildren) |i| {
        const c = &children[i];
        if (c.state == .blocked and c.wait_kind == kind) c.state = .runnable;
    }
}

// virtio's parkOnce calls here when a request can't complete yet: in a
// live epoch the wait is a real block (yield to the roster); outside one
// there is no schedulable context and the caller keeps its hlt path.
// Returns nonzero if it blocked-and-woke. Called with IF=0; returns IF=1.
export fn koru_blk_sleep() callconv(.c) c_int {
    if (!sched_active or nchildren == 0) return 0;
    kblock(.blk);
    return 1;
}

// Kernel-context switch: kblock() calls here like a function; we push
// the callee-saved set on the CURRENT child's kstack (the whole live
// call chain above stays put — that is the point of per-child kstacks)
// and tail into ksched, which schedules on this same stack. A later
// switchInto pops the block and rets — control lands back in kblock's
// caller as if the call had returned, the syscall completing itself.
comptime {
    asm (
        \\ .section .text
        \\ .globl koru_kblock
        \\ koru_kblock:
        \\   push %rbp
        \\   push %rbx
        \\   push %r12
        \\   push %r13
        \\   push %r14
        \\   push %r15
        \\   mov %rsp, %rdi
        \\   jmp ksched
    );
}
extern fn koru_kblock() void;

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
        \\   movq $0, child_entry(%rip)
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
        \\   movq $1, child_entry(%rip)
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
pub export fn koru_spawn_run(imgs: [*]const [*]const u8, sizes: [*]const usize, rights: [*]const u64, n: usize, fsv: ?*const ChildFsOps) callconv(.c) c_int {
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
        c.fsv = fsv;
        c.fds = .{0} ** 8;
        // provider children get the stdio projection too — stdio is a
        // typed entry now, not an fd-number special case
        c.fdkinds = .{ .conin, .conout, .conout, .none, .none, .none, .none, .none };
        c.fdverbs = .{ V_READ, V_WRITE, V_WRITE, 0, 0, 0, 0, 0 };
        var ipath: [256]u8 = undefined;
        var ilen: usize = 0;
        const info = loadElf(c, imgs[i][0..sizes[i]], USER_VA_BASE, &ipath, &ilen) orelse {
            say("ELF LOAD FAIL\n");
            return -2;
        };
        var entry = info.entry;
        var at_base: u64 = 0;
        if (ilen > 0) { // PT_INTERP — resolve the loader through the fs view
            if (c.fsv == null) {
                say("ELF REFUSE: PT_INTERP needs an fs view\n");
                return -2;
            }
            const iname = std.mem.sliceTo(ipath[0..ilen], 0);
            const iinfo = loadElfViaFs(c, iname, INTERP_BASE, null, null) orelse {
                say("ELF REFUSE: PT_INTERP loader unreadable\n");
                return -2;
            };
            at_base = INTERP_BASE;
            entry = iinfo.entry;
        }
        c.rights = rights[i];
        c.frame = std.mem.zeroes(UserFrame);
        c.frame.rip = entry;
        c.frame.cs = 0x23; // user code64
        c.frame.rflags = 0x202; // IF=1 — the child may be ticked mid-flight
        c.frame.rsp = buildStack(c, info, at_base, std.mem.sliceTo(child_arg0[0..], 0)) orelse return -1;
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
    say(" kctx=");
    koru_putdec(kctx_resumes);
    say(" tick_kctx=");
    koru_putdec(tick_kctx);
    say(" pipe: rd=");
    koru_putdec(pipe_reads);
    say(" wr=");
    koru_putdec(pipe_writes);
    say(" rwaits=");
    koru_putdec(pipe_rwaits);
    say(" wwaits=");
    koru_putdec(pipe_wwaits);
    say(" forks=");
    koru_putdec(forks);
    say(" fpages=");
    koru_putdec(fork_pages);
    say("\n");
    return @intCast(last_exit);
}

// Spawn a caller-supplied ELF64 image in a fresh child space. The single-
// child spelling of koru_spawn_run — blocks until the child exits through
// the seam; returns its exit code (< 0 on setup refusal). `fsv` scopes the
// child's fs view: the spawning fs hands down its ops record — a child
// spawned without one (embedded, hostexec, spawn:exec) gets ENOSYS on
// open, not a borrowed fs.
pub export fn koru_spawn_elf(image: [*]const u8, size: usize, rights: u64, fsv: ?*const ChildFsOps) callconv(.c) c_int {
    var imgs = [_][*]const u8{image};
    var szs = [_]usize{size};
    var rts = [_]u64{rights};
    return koru_spawn_run(&imgs, &szs, &rts, 1, fsv);
}

// No-disk evidence path: spawn the embedded child once.
pub fn run() void {
    const st = koru_spawn_elf(&child_elf, child_elf.len, (1 << 1) | (1 << 60), null);
    say("EMBED SPAWN exit=");
    puthex(@intCast(@as(u32, @bitCast(st))));
    say("\n");
}
