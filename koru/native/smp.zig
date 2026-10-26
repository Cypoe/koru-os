// koru/native smp — AP bringup over INIT-SIPI-SIPI.
//
// MADT named the roster (acpi.apicIds); this file is the door that turns
// a name into a running CPU. The trampoline is one page of real-mode
// code at 0x8000 — the only legal SIPI landing zone (<1 MiB, page-
// aligned) — pmm-reserved so the frame allocator can never hand it out.
// The AP climbs the same PAE+long-mode ladder _start did, reusing the
// BSP's page tables (pml4) and gdt64 — both reached as absolute
// addresses because the image is position-fixed and identity-mapped —
// then calls apMain on its own frame for a stack.
//
// The protocol is a handshake, not fire-and-forget: the BSP writes the
// params block into the page, pulses INIT + two SIPIs through the ICR,
// and spins on the AP's ack with a tick-bounded deadline. A silent AP
// is named refused, never assumed. APs park in hlt after acking —
// roster membership in sched is a later cell.

const std = @import("std");
const acpi = @import("acpi");
const pmm = @import("pmm");
const mmio = @import("mmio");

extern fn koru_say(s: [*:0]const u8) void;
extern var irq_ticks: u64; // user.zig — PIT IRQ0 count, ~18.2 Hz default
extern var pml4: [512]u64; // boot.zig — BSP page tables, shared with APs

fn say(s: [*:0]const u8) void {
    koru_say(s);
}
fn sayf(comptime fmt: []const u8, args: anytype) void {
    var buf: [192]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf, fmt, args) catch return;
    koru_say(s.ptr);
}

const TRAMP: usize = 0x8000;
// Params block inside the trampoline page — offsets must match the asm.
const O_CR3: usize = 0x700; // u64 — phys of pml4
const O_STACK: usize = 0x708; // u64 — rsp for the AP
const O_ENTRY: usize = 0x710; // u64 — call target (apMain)
const O_APICID: usize = 0x718; // u32 — the AP's own id, written by the BSP

extern const ap_tramp_start: u8;
extern const ap_tramp_end: u8;

// Real-mode entry (SIPI lands here at 0x8000), temp 32-bit GDT in-page,
// then the BSP's CR3 + gdt64 for the long jump. Absolute addressing is
// legal because the page's physical home is fixed — no relocation pass.
comptime {
    asm (
        \\ .extern gdt64_ptr
        \\ .globl ap_tramp_start, ap_tramp_end
        \\ .code16
        \\ ap_tramp_start:
        \\   cli
        \\   cld
        \\   xorw %ax, %ax
        \\   movw %ax, %ds
        \\   lgdtl (0x8000 + ap_gdtptr - ap_tramp_start)
        \\   movl %cr0, %eax
        \\   orl $1, %eax
        \\   movl %eax, %cr0
        \\   ljmpl $0x08, $(0x8000 + ap_pm - ap_tramp_start)
        \\ .code32
        \\ ap_pm:
        \\   movw $0x10, %ax
        \\   movw %ax, %ds
        \\   movw %ax, %es
        \\   movw %ax, %ss
        \\   movl (0x8000 + 0x700), %eax
        \\   movl %eax, %cr3
        \\   movl %cr4, %eax
        \\   orl $0x620, %eax
        \\   movl %eax, %cr4
        \\   movl $0xC0000080, %ecx
        \\   rdmsr
        \\   orl $0x100, %eax
        \\   wrmsr
        \\   movl %cr0, %eax
        \\   andl $0xFFFFFFFB, %eax
        \\   orl $0x80000003, %eax
        \\   movl %eax, %cr0
        \\   lgdtl gdt64_ptr
        \\   ljmpl $0x08, $(0x8000 + ap_lm - ap_tramp_start)
        \\ .code64
        \\ ap_lm:
        \\   movw $0x10, %ax
        \\   movw %ax, %ds
        \\   movw %ax, %es
        \\   movw %ax, %ss
        \\   movw %ax, %fs
        \\   movw %ax, %gs
        \\   movq (0x8000 + 0x708), %rsp
        \\   xorl %ebp, %ebp
        \\   movq (0x8000 + 0x710), %rax
        \\   call *%rax
        \\ 9: hlt
        \\   jmp 9b
        \\ .balign 8
        \\ ap_gdt:
        \\   .quad 0
        \\   .quad 0x00CF9A000000FFFF
        \\   .quad 0x00CF92000000FFFF
        \\ ap_gdtptr:
        \\   .word (ap_gdtptr - ap_gdt - 1)
        \\   .long (0x8000 + ap_gdt - ap_tramp_start)
        \\ ap_tramp_end:
        \\ .code64
    );
}

fn lapic(reg: u32) *volatile u32 {
    return @ptrFromInt(@as(usize, @intCast(acpi.lapicPhys)) + reg);
}

// ICR0 command to physical-dest `id`. Level-assert INIT is 0x4500;
// SIPI is 0x4600|vector where vector = trampoline page >> 12. ICR high
// dword first — writing the low dword triggers the send.
fn ipiSend(id: u8, cmd: u32) void {
    lapic(0x310).* = @as(u32, id) << 24;
    lapic(0x300).* = cmd;
    while ((lapic(0x300).* & (1 << 12)) != 0) {} // delivery status out
}

fn waitTicks(n: u64) void {
    const d = irq_ticks + n;
    while (irq_ticks < d) asm volatile ("hlt");
}

pub var apAcked: u32 = 0;
pub var apSeenId: u32 = 0;

// The AP's first kernel code — reads its id from the params block,
// acks, parks. Prints stay BSP-side (no serial lock on this arm yet);
// the mailbox IS the AP's voice.
export fn apMain() callconv(.c) noreturn {
    const id = @as(*volatile u32, @ptrFromInt(TRAMP + O_APICID)).*;
    apSeenId = id;
    @atomicStore(u32, &apAcked, 1, .seq_cst);
    while (true) asm volatile ("hlt");
}

pub fn init() void {
    if (acpi.ncpusEnabled <= 1) {
        say("smp: uniprocessor — no AP bringup\n");
        return;
    }
    _ = mmio.map(acpi.lapicPhys, 0x1000);
    const bsp: u8 = @truncate(lapic(0x20).* >> 24);
    sayf("smp: bsp id={d} — {d} ap(s) in the madt roster\n", .{
        bsp, acpi.ncpusEnabled - 1,
    });

    // The trampoline page is e820-usable — reserve it permanently or a
    // wrapped alloc pass could hand a program the code our AP runs.
    pmm.reserve(TRAMP, 0x1000);
    const n = @intFromPtr(&ap_tramp_end) - @intFromPtr(&ap_tramp_start);
    if (n > O_CR3) {
        sayf("smp: trampoline {d}B overruns params — REFUSED\n", .{n});
        return;
    }
    const dst: [*]u8 = @ptrFromInt(TRAMP);
    const src: [*]const u8 = @ptrFromInt(@intFromPtr(&ap_tramp_start));
    @memcpy(dst[0..n], src[0..n]);

    lapic(0xF0).* |= 0x1FF; // SVR — spurious vector + LAPIC enable

    var i: usize = 0;
    var brought: usize = 0;
    while (i < acpi.ncpus) : (i += 1) {
        const id = acpi.apicIds[i];
        if (id == bsp) continue;
        if (startAp(id)) brought += 1;
    }
    sayf("smp: {d}/{d} ap(s) online\n", .{ brought, acpi.ncpusEnabled - 1 });
}

fn startAp(id: u8) bool {
    const stk = pmm.alloc() orelse {
        say("smp: no frame for AP stack — refused\n");
        return false;
    };
    const pw = struct {
        fn u64s(a: usize) *volatile u64 {
            return @ptrFromInt(a);
        }
        fn u32s(a: usize) *volatile u32 {
            return @ptrFromInt(a);
        }
    };
    pw.u64s(TRAMP + O_CR3).* = @intFromPtr(&pml4); // link addr == phys
    pw.u64s(TRAMP + O_STACK).* = stk + 0x1000;
    pw.u64s(TRAMP + O_ENTRY).* = @intFromPtr(&apMain);
    pw.u32s(TRAMP + O_APICID).* = id;
    apAcked = 0;

    ipiSend(id, 0x4500); // INIT assert — level, INIT delivery, phys dest
    waitTicks(1); // spec floor is 10 ms; one ~55 ms tick is honest margin
    ipiSend(id, 0x4600 | (TRAMP >> 12)); // SIPI — vector = page
    waitTicks(1);
    ipiSend(id, 0x4600 | (TRAMP >> 12)); // second, per the Intel protocol

    const deadline = irq_ticks + 40; // ~2 s at 18.2 Hz — generous
    while (irq_ticks < deadline and
        @atomicLoad(u32, &apAcked, .seq_cst) == 0) asm volatile ("hlt");
    if (apAcked != 0) {
        sayf("smp: ap id={d} online\n", .{id});
        return true;
    }
    sayf("smp: ap id={d} REFUSED — no ack in 40 ticks\n", .{id});
    return false;
}
