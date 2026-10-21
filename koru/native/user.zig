// koru/native user — ring3 entry + the embryonic syscall seam for the
// spawn rung-2 family. A child address space gets user (U/S) pages at
// VA 0x400000 (code) / 0x401000 (stack); iretq drops to ring3, the child
// writes a marker byte into its own page and raises int 0x80 — the IDT
// trap gate switches to TSS.rsp0 and the ring0 handler reports the byte
// on serial ("RING3 OK") then halts.
//
// Honest scope: raw machine-code child (ELF loading is the next rung),
// int-based seam not SYSCALL/SYSRET, no scheduler — the child runs once
// and the demo ends in halt. Kernel pages are NOT user-accessible in the
// child space (U/S clear on identity entries): the isolation direction
// is real, not a shared-page demo.

extern var pml4: [512]u64;
extern var pdpt: [512]u64;
extern var pd: [512]u64;

extern var stdout: ?*anyopaque;
extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern fn posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) callconv(.c) c_int;

const ENT: u64 = 0x3; // present | writable
const US: u64 = 0x4; // user-accessible
const PS: u64 = 0x80;

const USER_VA: usize = 0x800000; // pd[4] -> pt page -> 4K user mappings
const USER_STACK_TOP: usize = 0x802000; // second user page, top

fn say(s: [*:0]const u8) void {
    _ = fputs(s, stdout);
}

// ---- GDT/TSS/IDT ---------------------------------------------------------
// gdt2 mirrors the boot GDT then adds user data/code + a 128-bit TSS
// descriptor patched in at runtime (its base is a runtime address).
var gdt2: [8]u64 align(8) = .{
    0x0000000000000000,
    0x00AF9A000000FFFF, // 0x08 kernel code64
    0x00CF92000000FFFF, // 0x10 kernel data
    0x00CFF2000000FFFF, // 0x18 user data   (DPL=3)
    0x00AFFA000000FFFF, // 0x20 user code64 (DPL=3, L)
    0, 0, 0,            // 0x28 TSS descriptor (two quads) + pad
};
var tss: [104]u8 align(16) = [_]u8{0} ** 104;
var idt: [512]u64 align(16) = [_]u64{0} ** 512;
var kstack: [4096]u8 align(16) = [_]u8{0} ** 4096;

fn patchTssDesc() void {
    const base: u64 = @intFromPtr(&tss);
    const limit: u64 = 103;
    // low quad: limit[15:0] | base[23:0]<<16 | type 0x89<<40 | base[31:24]<<56
    gdt2[5] = (limit & 0xFFFF) | ((base & 0xFFFFFF) << 16) |
        (0x89 << 40) | (((base >> 24) & 0xFF) << 56);
    gdt2[6] = base >> 32;
}

fn setIdtGate(idx: usize, handler: usize, dpl3: bool) void {
    const attr: u64 = if (dpl3) 0xEE else 0x8E; // int gate, present, DPL
    const lo: u64 = (handler & 0xFFFF) | (0x08 << 16) | (attr << 40) |
        (((handler >> 16) & 0xFFFF) << 48);
    const hi: u64 = handler >> 32;
    idt[idx * 2] = lo;
    idt[idx * 2 + 1] = hi;
}

extern fn ring3_entry80() void;

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
    // tss.rsp0 = top of dedicated kernel stack for ring3->ring0 switches
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
}

// ---- child space ----------------------------------------------------------

var c_pml4: *align(4096) [512]u64 = undefined;
var c_pdpt: *align(4096) [512]u64 = undefined;
var c_pd: *align(4096) [512]u64 = undefined;
var c_pt: *align(4096) [512]u64 = undefined;
var code_page: *align(4096) [4096]u8 = undefined;
var stack_page: *align(4096) [4096]u8 = undefined;

fn allocPage() ?*align(4096) [4096]u8 {
    var p: ?*anyopaque = null;
    if (posix_memalign(&p, 4096, 4096) != 0 or p == null) return null;
    const t: *align(4096) [4096]u8 = @ptrCast(@alignCast(p.?));
    @memset(t, 0);
    return t;
}

// movb $0x55, (0x800010); int $0x80; jmp $  — writes a marker, raises the
// seam, loops if control ever returns.
const child_code = [_]u8{ 0xC6, 0x04, 0x25, 0x10, 0x00, 0x80, 0x00, 0x55, 0xCD, 0x80, 0xEB, 0xFE };

fn buildChild() bool {
    c_pml4 = @ptrCast(@alignCast(allocPage() orelse return false));
    c_pdpt = @ptrCast(@alignCast(allocPage() orelse return false));
    c_pd = @ptrCast(@alignCast(allocPage() orelse return false));
    c_pt = @ptrCast(@alignCast(allocPage() orelse return false));
    code_page = allocPage() orelse return false;
    stack_page = allocPage() orelse return false;

    // U/S must hold at every level for ring3 to reach a leaf; the kernel
    // half stays protected because leaf pd[0..2] still lack the US bit.
    c_pml4[0] = @intFromPtr(c_pdpt) | US | ENT;
    c_pdpt[0] = @intFromPtr(c_pd) | US | ENT;
    c_pd.* = pd; // kernel+heap identity stays ring0-only (no U/S bit)
    c_pd[4] = @intFromPtr(c_pt) | US | ENT;
    c_pt[0] = @intFromPtr(code_page) | US | ENT;
    c_pt[1] = @intFromPtr(stack_page) | US | ENT;

    @memcpy(code_page[0..child_code.len], &child_code);
    return true;
}

comptime {
    asm (
        \\ .section .text
        \\ .globl ring3_entry80
        \\ ring3_entry80:
        \\   call ring3_report
        \\ 1: hlt
        \\   jmp 1b
    );
}

export fn ring3_report() callconv(.c) void {
    const marker: *volatile u8 = @ptrFromInt(USER_VA + 0x10);
    if (marker.* == 0x55) {
        say("RING3 OK: user child wrote marker, int 0x80 seam taken\n");
    } else {
        say("RING3 FAIL: marker not written\n");
    }
}

// Enter ring3 in the child space. Diverges by construction: the seam
// handler halts the machine after reporting.
pub fn demo() void {
    if (!buildChild()) {
        say("RING3 FAIL: page alloc\n");
        return;
    }
    loadTables();
    asm volatile (
        \\ mov %[cr3], %%rax
        \\ mov %%rax, %%cr3
        \\ push $0x1B
        \\ push %[stk]
        \\ push $0x202
        \\ push $0x23
        \\ push %[rip]
        \\ iretq
        :
        : [cr3] "r" (@intFromPtr(c_pml4)),
          [stk] "r" (@as(usize, USER_STACK_TOP)),
          [rip] "r" (@as(usize, USER_VA)),
        : .{ .memory = true });
    unreachable;
}
