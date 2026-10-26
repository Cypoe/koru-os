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
// Boot info: EBX carries the loader's info pointer — under QEMU -kernel
// that is a Xen PVH hvm_start_info (the .note.Xen below), under GRUB a
// multiboot2 info block. pmm.init detects which by the head word and reads
// the memory map either way; fb.init reads mb2 tag 8 (GRUB) or falls back
// to programming BGA itself.

const prog = @import("program");
const runtime = @import("runtime");
const virtio = @import("virtio");
const aspace = @import("aspace");
const user = @import("user");
const fb = @import("fb.zig");
const pmm = @import("pmm");
const kbd = @import("kbd");
const pci = @import("pci");
const acpi = @import("acpi");
const smp = @import("smp");
const gpu = @import("gpu.zig");
const surf = @import("surf.zig");
const mouse = @import("mouse");
const comp = @import("comp");

comptime {
    // force-emission: lazy codegen only emits decls reachable from the
    // root — taking the address of each exported provider keeps the
    // extern contract the program links against actually in the image.
    _ = &runtime.posix_memalign;
    _ = &runtime.free;
    _ = &runtime.malloc;
    _ = &runtime.memalign;
    _ = &runtime.fputs;
    _ = &runtime.fwrite;
    _ = &runtime.ukplat_monotonic_clock;
    _ = &runtime.stdout;
    _ = &runtime.stderr;
    _ = &runtime._uk_alloc_head;
    _ = &virtio.uk_blkdev_get;
    _ = &virtio.uk_blkdev_configure;
    _ = &virtio.uk_blkdev_queue_get_info;
    _ = &virtio.uk_blkdev_queue_configure;
    _ = &virtio.uk_blkdev_queue_submit_one;
    _ = &virtio.uk_blkdev_queue_finish_reqs;
    _ = &virtio.uk_blkdev_start;
    _ = &virtio.uk_blkdev_stop;
    _ = &virtio.uk_blkdev_queue_unconfigure;
    _ = &virtio.uk_blkdev_unconfigure;
    _ = &gpu.gpu_irq_ack;
    _ = &gpu.gpu_msix_vec;
    _ = &gpu.gpu_msix_seen;
    _ = &surf.koruos_surface_open;
    _ = &surf.koruos_surface_fill;
    _ = &surf.koruos_surface_px;
    _ = &surf.koruos_surface_present;
    _ = &surf.koruos_surface_close;
    _ = &mouse.mouse_irq;
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
        \\   .short 5          // framebuffer request tag — asks the loader
        \\   .short 1          //   for a linear fb (optional: boot still
        \\   .long 20          //   proceeds if the loader can't give one)
        \\   .long 1024
        \\   .long 768
        \\   .long 32
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

// Page tables for the boot address space. Exported (not asm-local) so the
// aspace provider can clone them for per-domain CR3s. Layout: pml4[0] ->
// pdpt[0] -> pd[0..15] = 2 MiB pages identity-mapping 0-32 MiB here;
// pmm.init extends pd[16..] to the discovered RAM limit (cap 1 GiB).
export var pml4: [512]u64 align(4096) = undefined;
export var pdpt: [512]u64 align(4096) = undefined;
export var pd: [512]u64 align(4096) = undefined;

// _start: 32-bit entry. Identity-map 0..32MiB (pml4->pdpt->pd[0..16),
// sixteen 2 MiB pages — enough that the image's .bss (heap, pmm bitmaps)
// is always reachable; pmm.init extends the map to the discovered limit),
// load CR3, set CR4.PAE + EFER.LME + CR0.PG, then ljmp into the 64-bit
// code segment. The GDT descriptors live below in .rodata.
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
    \\   xorl %ecx, %ecx
    \\ 1: movl %ecx, %eax
    \\   shll $21, %eax
    \\   orl $0x83, %eax
    \\   movl %eax, pd(,%ecx,8)
    \\   incl %ecx
    \\   cmpl $16, %ecx
    \\   jb 1b
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
    \\   movl %ebx, %edi      // mbi phys addr — EBX survives the 32→64 path
    \\   call kmain
    \\ 1: hlt
    \\   jmp 1b
    \\ .section .rodata
    \\ .balign 8
    \\ .globl gdt64_ptr        // AP trampolines reuse this GDT for the long jump
    \\ gdt64:
    \\   .quad 0x0000000000000000
    \\   .quad 0x00AF9A000000FFFF
    \\   .quad 0x00CF92000000FFFF
    \\ gdt64_ptr:
    \\   .word gdt64_ptr - gdt64 - 1
    \\   .quad gdt64
    \\ .section .bss
        \\ .balign 16
        \\ __stack_bottom: .skip 524288
        \\ __stack_top:
    );
}

// The program's Zig entry. The emitted program returns void from `main`;
// anything it leaves on the console is the boot evidence. `mbi` is the
// multiboot2 info block's physical address (EBX at _start).
export fn kmain(mbi: u32) callconv(.c) noreturn {
    pmm.init(mbi); // frames live before anything allocates
    acpi.init(mbi); // RSDP + table directory — MADT/FACP names resolved
    pci.init();  // config-space scan while IF=0 — the dump can't
                 // interleave with IRQ prints; providers look up, never
                 // rescan
    user.init(); // IDT + PIC + sti — interrupts live before the program
    kbd.init();  // 8042 drain + IRQ1 — input events queue from here on
    mouse.init(); // 8042 aux channel — PS/2 mouse, IRQ12
    smp.init();  // INIT-SIPI-SIPI — APs ack + park before userland runs
    fb.init(mbi);
    comp.init(); // nativeCompositor — owns the scanout's scene from here
    aspace.selftest();
    prog.main();
    user.run();
    while (true) asm volatile ("hlt");
}
