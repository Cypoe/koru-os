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
const ioapic = @import("ioapic");
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
    \\   call kbled
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
    \\   call kbled
    \\   movw $0x10, %ax
    \\   movw %ax, %ds
    \\   movw %ax, %es
    \\   movw %ax, %ss
    \\   movw %ax, %fs
    \\   movw %ax, %gs
    \\   movq $__stack_top, %rsp
    \\   xorl %ebp, %ebp
    \\   movl %ebx, %edi      // mbi phys addr — EBX survives the 32→64 path
    \\   call kbled
    \\   call kmain
    \\ 1: hlt
    \\   jmp 1b
    \\ kbled:
    \\   mov $32, %ecx
    \\ .kd: inb $0x64, %al
    \\   test $1, %al
    \\   jz .kdd
    \\   inb $0x60, %al
    \\   loop .kd
    \\ .kdd:
    \\   mov $0xED, %al
    \\   mov $0x64, %dx
    \\   out %al, %dx
    \\   mov $0x1000, %ecx
    \\ .kd1: loop .kd1
    \\   mov $0x04, %al
    \\   mov $0x60, %dx
    \\   out %al, %dx
    \\   mov $0x4000000, %ecx
    \\ .kdl: loop .kdl
    \\   mov $0xED, %al
    \\   mov $0x64, %dx
    \\   out %al, %dx
    \\   mov $0x1000, %ecx
    \\ .kd2: loop .kd2
    \\   xor %eax, %eax
    \\   mov $0x60, %dx
    \\   out %al, %dx
    \\   mov $0x4000000, %ecx
    \\ .kdl2: loop .kdl2
    \\   ret
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
// PC-speaker stage beeps — bare-metal progress codes for hardware with
// no serial and no visible fb: N short beeps after stage N of kmain.
// PIT channel 2 (ports 0x42/0x43) gated through port 0x61 bit 1.
fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port)
        : .{ .memory = true });
}
fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port)
        : .{ .memory = true });
}
fn spinCycles(n: u64) void {
    var i: u64 = n;
    while (i != 0) : (i -= 1) asm volatile ("pause");
}
fn kbc_drain() void {
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        if (inb(0x64) & 0x01 == 0) break;
        _ = inb(0x60);
    }
}
fn kbc_wait_ibf() void {
    var i: usize = 0;
    while (inb(0x64) & 0x02 != 0) : (i += 1) {
        if (i > 1000000) return;
    }
}
fn kbc_cmd(c: u8) void {
    kbc_wait_ibf();
    outb(0x64, c);
}
fn kbc_dat(d: u8) void {
    kbc_wait_ibf();
    outb(0x60, d);
}
fn kbc_ack() void {
    var i: usize = 0;
    while (i < 100000) : (i += 1) {
        if (inb(0x64) & 0x01 != 0) {
            if (inb(0x60) == 0xFA) return;
        }
    }
}
fn ledSet(mask: u8) void {
    kbc_drain();
    kbc_cmd(0xED); // set LEDs
    kbc_ack();
    kbc_dat(mask); // bit0 scroll, bit1 num, bit2 caps
    kbc_ack();
}
fn blinkOnce() void {
    ledSet(0x04); // caps on
    spinCycles(40_000_000);
    ledSet(0x00); // caps off
    spinCycles(40_000_000);
}
fn beepStage(n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) blinkOnce();
}

// Force VGA text mode 3 (80x25) — makes 0xB8000 scannable regardless of
// what graphics mode the firmware/loader left behind. Standard register
// block; CRTC unlocked before writing, AC flip-flop reset first.
fn vga_wr(idx_port: u16, data_port: u16, idx: u8, val: u8) void {
    outb(idx_port, idx);
    outb(data_port, val);
}
fn vga_text_mode() void {
    const seq = [_]u8{ 0x03, 0x01, 0x0F, 0x00, 0x0E };
    const crtc = [_]u8{
        0x5F, 0x4F, 0x50, 0x82, 0x55, 0x81, 0xBF, 0x1F,
        0x00, 0x4F, 0x0D, 0x0E, 0x00, 0x00, 0x9C, 0x8F,
        0x28, 0x1F, 0x96, 0xB9, 0xA3, 0xFF,
    };
    const gc = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x05, 0x0F, 0xFF };
    const ac_tail = [_]u8{ 0x41, 0x00, 0x0F, 0x00, 0x00 };
    outb(0x3C2, 0x63); // misc output
    for (seq, 0..) |v, i| vga_wr(0x3C4, 0x3C5, @intCast(i), v);
    // unlock CRTC: reg3 |= 0x80, reg0x11 &= ~0x80
    outb(0x3D4, 0x03);
    outb(0x3D5, inb(0x3D5) | 0x80);
    outb(0x3D4, 0x11);
    outb(0x3D5, inb(0x3D5) & ~@as(u8, 0x80));
    for (crtc, 0..) |v, i| vga_wr(0x3D4, 0x3D5, @intCast(i), v);
    for (gc, 0..) |v, i| vga_wr(0x3CE, 0x3CF, @intCast(i), v);
    _ = inb(0x3DA); // reset AC flip-flop
    var ai: u8 = 0;
    while (ai < 16) : (ai += 1) {
        outb(0x3C0, ai);
        outb(0x3C0, ai);
    }
    for (ac_tail, 0..) |v, i| {
        outb(0x3C0, @intCast(16 + i));
        outb(0x3C0, v);
    }
    outb(0x3C0, 0x20); // re-enable display
}

export fn kmain(mbi: u32) callconv(.c) noreturn {
    vga_text_mode();
    beepStage(1); // kmain entry reached
    pmm.init(mbi); // frames live before anything allocates
    beepStage(2);
    acpi.init(mbi); // RSDP + table directory — MADT/FACP names resolved
    beepStage(3);
    pci.init();  // config-space scan while IF=0 — the dump can't
                 // interleave with IRQ prints; providers look up, never
                 // rescan
    beepStage(4);
    ioapic.init(); // GSI routes armed (masked) — every later unmask
                   // takes the LAPIC door; PIC lines masked for good
    beepStage(5);
    user.init(); // IDT + PIC + sti — interrupts live before the program
    beepStage(6);
    kbd.init();  // 8042 drain + IRQ1 — input events queue from here on
    beepStage(7);
    mouse.init(); // 8042 aux channel — PS/2 mouse, IRQ12
    beepStage(8);
    smp.init();  // INIT-SIPI-SIPI — APs ack + park before userland runs
    beepStage(9);
    fb.init(mbi);
    beepStage(10);
    comp.init(); // nativeCompositor — owns the scanout's scene from here
    beepStage(11);
    aspace.selftest();
    prog.main();
    user.run();
    while (true) asm volatile ("hlt");
}
