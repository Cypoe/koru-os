// koruos/native boot stub — multiboot2 entry for the `koru-native` arm.
//
// QEMU `-kernel` and GRUB find the multiboot2 header by scanning the first
// 32 KiB of the image; link.ld places .multiboot first. The loader drops us
// in 32-bit protected mode (long mode off), so `_start` identity-maps the
// first 4 MiB, enables PAE + LME, and far-jumps into the 64-bit half —
// where `kmain` installs the real stack and calls the emitted program's
// `main` (module `program`, bound by build-native.sh). This stub knows
// nothing about the program beyond the symbol it calls.
//
// Multiboot information (magic in EAX, info ptr in EBX) is ignored for now —
// the boot program needs no cmdline/modules yet; when one does, kmain's
// signature becomes the seam.

const prog = @import("program");
const runtime = @import("runtime");

comptime {
    // force-emission: lazy codegen only emits decls reachable from the
    // root — taking the address of each exported provider keeps the
    // extern contract the program links against actually in the image.
    _ = &runtime.posix_memalign;
    _ = &runtime.free;
    _ = &runtime.fputs;
    _ = &runtime.ukplat_monotonic_clock;
    _ = &runtime.stdout;
    _ = &runtime.stderr;
}

// multiboot2 header — magic, architecture (i386), length, checksum, end tag.
comptime {
    asm (
        \\ .section .multiboot, "a"
        \\ .balign 8
        \\ mb2_header:
        \\   .long 0xE85250D6
        \\   .long 0
        \\   .long mb2_end - mb2_header
        \\   .long -(0xE85250D6 + 0 + (mb2_end - mb2_header))
        \\   .balign 8
        \\   .short 0
        \\   .short 0
        \\   .long 8
        \\ mb2_end:
        \\ .section .note.Xen, "a", @note
        \\ .balign 4
        \\   .long 4
        \\   .long 4
        \\   .long 18
        \\   .ascii "Xen\000"
        \\ .balign 4
        \\   .long _start
    );
}

// _start: 32-bit entry. Identity-map 0..4MiB (pml4->pdpt->pd, two 2 MiB
// pages), load CR3, set CR4.PAE + EFER.LME + CR0.PG, then ljmp into the
// 64-bit code segment. The GDT/code/data descriptors and the page-table
// pages live below, emitted by the same asm block.
comptime {
    asm (
        \\ .section .text
        \\ .code32
    \\ .globl _start
    \\ _start:
    \\   cli
    \\   movl $pdpt, %eax
    \\   orl $0x3, %eax
    \\   movl %eax, pml4
    \\   movl $pd, %eax
    \\   orl $0x3, %eax
    \\   movl %eax, pdpt
    \\   movl $0x000083, %eax
    \\   movl %eax, pd
    \\   movl $0x200083, %eax
    \\   movl %eax, pd+8
    \\   movl $0x400083, %eax
    \\   movl %eax, pd+16
    \\   movl $pml4, %eax
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
    \\   lgdt gdt64_ptr
    \\   ljmp $0x08, $start64
    \\ .code64
    \\ start64:
    \\   movw $0x10, %ax
    \\   movw %ax, %ds
    \\   movw %ax, %es
    \\   movw %ax, %ss
    \\   movw %ax, %fs
    \\   movw %ax, %gs
    \\   movq $__stack_top, %rsp
    \\   xorl %ebp, %ebp
    \\   call kmain
    \\ 1: hlt
    \\   jmp 1b
    \\ .section .rodata
    \\ .balign 8
    \\ gdt64:
    \\   .quad 0x0000000000000000
    \\   .quad 0x00AF9A000000FFFF
    \\   .quad 0x00CF92000000FFFF
    \\ gdt64_ptr:
    \\   .word gdt64_ptr - gdt64 - 1
    \\   .quad gdt64
    \\ .section .bss
    \\ .balign 4096
    \\ pml4: .skip 4096
    \\ pdpt: .skip 4096
    \\ pd:   .skip 4096
        \\ .balign 16
        \\ __stack_bottom: .skip 524288
        \\ __stack_top:
    );
}

// The program's Zig entry. The emitted program returns void from `main`;
// anything it leaves on the console is the boot evidence.
export fn kmain() callconv(.c) noreturn {
    prog.main();
    while (true) asm volatile ("hlt");
}
