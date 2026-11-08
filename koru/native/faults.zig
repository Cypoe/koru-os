// koru/native/faults — minimal IDT so exceptions FREEZE with evidence
// instead of triple-faulting back to the bootloader.
//
// Before this: no IDT on the consoleMode path -> any #PF/#GP/#UD/MCE
// double-faults -> CPU reset -> POST -> GRUB redraws -> every on-screen
// marker wiped. A crash was indistinguishable from "never got there".
//
// Now: vectors 0-21 (except NMI=2, which must stay deliverable) get
// gates to tiny asm stubs that tail-jmp isrReport -> prints vector (+CR2
// for #PF) to serial AND the fb text console, then cli+hlt forever.
// A frozen screen IS the crash report; GRUB never returns.
//
// Gate format cribbed from user.zig setIdtGate: selector 0x08 = boot
// GDT kernel code (ljmp $0x08 in the trampoline), attr 0x8E =
// present|DPL0|64-bit interrupt gate.

const text = @import("text.zig");
const led = @import("led.zig");

extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;

var idt: [512]u64 align(16) = [_]u64{0} ** 512;

// isrTable[v] = handler addr for exception vector v (0 for NMI slot).
extern const isrTable: [22]usize;

fn setIdtGate(idx: usize, handler: usize) void {
    const attr: u64 = 0x8E; // P=1 DPL=0 type=1110 (64-bit int gate), IST=0
    const lo: u64 = (@as(u64, @intCast(handler)) & 0xFFFF) |
        (0x08 << 16) | (attr << 40) |
        (((@as(u64, @intCast(handler)) >> 16) & 0xFFFF) << 48);
    idt[idx * 2] = lo;
    idt[idx * 2 + 1] = @as(u64, @intCast(handler)) >> 32;
}

pub fn install() void {
    for (isrTable, 0..) |h, i| {
        if (h != 0) setIdtGate(i, h);
    }
    var p: [10]u8 = undefined;
    const base = @intFromPtr(&idt);
    const limit: u16 = @intCast(idt.len * 8 - 1);
    p[0] = @intCast(limit & 0xFF);
    p[1] = @intCast(limit >> 8);
    var i: usize = 0;
    while (i < 8) : (i += 1) p[2 + i] = @intCast((base >> @as(u6, @intCast(8 * i))) & 0xFF);
    asm volatile ("lidtq %[p]" : : [p] "m" (p) : .{ .memory = true });
}

fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[v]" : [v] "=r" (-> u64));
}

// Called (tail-jmp'd) from every exception stub with edi = vector.
// Never returns: report then halt. If the fault corrupted whatever the
// text path needs, koru_say still carries it for anyone with a UART.
pub export fn isrReport(vec: u64) callconv(.c) noreturn {
    led.crash();
    koru_say("!! EXCEPTION vec=");
    koru_putdec(vec);
    koru_say("\n");
    if (vec == 14) { // #PF — the faulting linear address is the whole story
        const cr2 = readCr2();
        koru_say("!! CR2=");
        koru_putdec(cr2);
        koru_say("\n");
        if (text.dims().w != 0) {
            text.puts("!! PF cr2=");
            text.putdec(cr2);
            text.newline();
        }
    }
    if (text.dims().w != 0) {
        text.puts("!! EXCEPTION vec=");
        text.putdec(vec);
        text.newline();
        text.puts("(frozen — no reset)\n");
    }
    while (true) {
        asm volatile ("cli\n\thlt");
    }
}

// One stub per vector: align stack, set edi=vector, tail-jmp report.
// NMI (2) deliberately absent — a stray NMI must not freeze the box.
comptime {
    asm (
        \\ .text
        \\ .p2align 4
        \\ .globl isrStub0
        \\ isrStub0: cli; and $-16, %rsp; mov $0, %edi; jmp isrReport
        \\ .globl isrStub1
        \\ isrStub1: cli; and $-16, %rsp; mov $1, %edi; jmp isrReport
        \\ .globl isrStub3
        \\ isrStub3: cli; and $-16, %rsp; mov $3, %edi; jmp isrReport
        \\ .globl isrStub4
        \\ isrStub4: cli; and $-16, %rsp; mov $4, %edi; jmp isrReport
        \\ .globl isrStub5
        \\ isrStub5: cli; and $-16, %rsp; mov $5, %edi; jmp isrReport
        \\ .globl isrStub6
        \\ isrStub6: cli; and $-16, %rsp; mov $6, %edi; jmp isrReport
        \\ .globl isrStub7
        \\ isrStub7: cli; and $-16, %rsp; mov $7, %edi; jmp isrReport
        \\ .globl isrStub8
        \\ isrStub8: cli; and $-16, %rsp; mov $8, %edi; jmp isrReport
        \\ .globl isrStub9
        \\ isrStub9: cli; and $-16, %rsp; mov $9, %edi; jmp isrReport
        \\ .globl isrStub10
        \\ isrStub10: cli; and $-16, %rsp; mov $10, %edi; jmp isrReport
        \\ .globl isrStub11
        \\ isrStub11: cli; and $-16, %rsp; mov $11, %edi; jmp isrReport
        \\ .globl isrStub12
        \\ isrStub12: cli; and $-16, %rsp; mov $12, %edi; jmp isrReport
        \\ .globl isrStub13
        \\ isrStub13: cli; and $-16, %rsp; mov $13, %edi; jmp isrReport
        \\ .globl isrStub14
        \\ isrStub14: cli; and $-16, %rsp; mov $14, %edi; jmp isrReport
        \\ .globl isrStub15
        \\ isrStub15: cli; and $-16, %rsp; mov $15, %edi; jmp isrReport
        \\ .globl isrStub16
        \\ isrStub16: cli; and $-16, %rsp; mov $16, %edi; jmp isrReport
        \\ .globl isrStub17
        \\ isrStub17: cli; and $-16, %rsp; mov $17, %edi; jmp isrReport
        \\ .globl isrStub18
        \\ isrStub18: cli; and $-16, %rsp; mov $18, %edi; jmp isrReport
        \\ .globl isrStub19
        \\ isrStub19: cli; and $-16, %rsp; mov $19, %edi; jmp isrReport
        \\ .globl isrStub20
        \\ isrStub20: cli; and $-16, %rsp; mov $20, %edi; jmp isrReport
        \\ .globl isrStub21
        \\ isrStub21: cli; and $-16, %rsp; mov $21, %edi; jmp isrReport
        \\ .p2align 3
        \\ .globl isrTable
        \\ isrTable:
        \\   .quad isrStub0
        \\   .quad isrStub1
        \\   .quad 0
        \\   .quad isrStub3
        \\   .quad isrStub4
        \\   .quad isrStub5
        \\   .quad isrStub6
        \\   .quad isrStub7
        \\   .quad isrStub8
        \\   .quad isrStub9
        \\   .quad isrStub10
        \\   .quad isrStub11
        \\   .quad isrStub12
        \\   .quad isrStub13
        \\   .quad isrStub14
        \\   .quad isrStub15
        \\   .quad isrStub16
        \\   .quad isrStub17
        \\   .quad isrStub18
        \\   .quad isrStub19
        \\   .quad isrStub20
        \\   .quad isrStub21
    );
}
