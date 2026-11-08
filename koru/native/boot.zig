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
const faults = @import("faults.zig");
const led = @import("led.zig");
const text = @import("text.zig");
const earlyfb = @import("earlyfb.zig");
const shell = @import("shell.zig");
const net = @import("net");

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
        \\ mb2_header_bytes: // emitted as export var below — zig 0.15.2
        \\                     // DCEs unreferenced .multiboot asm data
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

// multiboot2 header as export var — .multiboot section, KEEP()'d by link.ld.
// magic 0xE85250D6, arch i386, len=48, checksum, fb-request tag (32bpp),
// end tag. zig 0.15.2 dead-code-eliminates unreferenced comptime asm
// data — an export var cannot be dropped.
export const mb2_header: [48]u8 align(8) linksection(".multiboot") = .{
    0xD6, 0x50, 0x52, 0xE8, 0x00, 0x00, 0x00, 0x00, // magic 0xE85250D6 LE, arch=i386
    0x30, 0x00, 0x00, 0x00, 0xFA, 0xAE, 0xAD, 0x17, // len=48, checksum
    0x05, 0x00, 0x01, 0x00, 0x14, 0x00, 0x00, 0x00, // tag5 fb req, size 20
    0x00, 0x04, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, // 1024x768x32
    0x20, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // depth=32, pad->8
    0x00, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, // end tag
};

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
    // Replicates vgabios.c's mode-set sequence exactly (same order, same
    // writes) — tables from vgatables.h index=0x18 (mode 0x03).
    const ac = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x14, 0x07,
        0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
        0x0C, 0x00, 0x0F, 0x08,
    };
    const seqtab = [_]u8{ 0x00, 0x03, 0x00, 0x02 }; // -> seq idx 1..4
    const gc = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0E, 0x0F, 0xFF };
    const crtc = [_]u8{
        0x5F, 0x4F, 0x50, 0x82, 0x55, 0x81, 0xBF, 0x1F,
        0x00, 0x4F, 0x0D, 0x0E, 0x00, 0x00, 0x00, 0x00,
        0x9C, 0x8E, 0x8F, 0x28, 0x1F, 0x96, 0xB9, 0xA3,
        0xFF,
    };
    _ = inb(0x3DA); // reset AC flip-flop
    for (ac, 0..) |v, i| {
        outb(0x3C0, @intCast(i));
        outb(0x3C0, v);
    }
    outb(0x3C0, 0x14);
    outb(0x3C0, 0x00);
    outb(0x3C4, 0x00);
    outb(0x3C5, 0x03); // sequencer idx0 = 0x03 (BIOS hardcodes this)
    for (seqtab, 0..) |v, i| vga_wr(0x3C4, 0x3C5, @intCast(i + 1), v);
    for (gc, 0..) |v, i| vga_wr(0x3CE, 0x3CF, @intCast(i), v);
    outb(0x3D4, 0x11);
    outb(0x3D5, 0x00); // CRTC write-protect off
    for (crtc, 0..) |v, i| vga_wr(0x3D4, 0x3D5, @intCast(i), v);
    outb(0x3C2, 0x67); // misc output
    outb(0x3C0, 0x20); // AC idx 0x20 — display enable
    _ = inb(0x3DA);
}

// Scanout probe: flood the text buffer with a solid bright attribute and
// stamp a marker — a colored screen proves 0xB8000 is being scanned in
// text mode; black means the display never entered it.
fn vga_debug() void {
    const vga: [*]volatile u16 = @ptrFromInt(0xB8000);
    var i: usize = 0;
    // full-block glyph + bright-white fg: every cell lit regardless of palette
    while (i < 80 * 25) : (i += 1) vga[i] = (@as(u16, 0x0F) << 8) | 0xDB;
    const msg = "KORU VGA TEXT OK";
    var r: usize = 0;
    while (msg[r] != 0) : (r += 1) vga[r] = (@as(u16, 0x70) << 8) | msg[r];
}

extern fn koru_say(s: [*:0]const u8) void;
extern fn koru_putdec(v: u64) void;

// DIAG: prove the adopted linear fb reaches the scanout — solid fill plus
// a green triangle, then the caller halts so comp can't repaint over it.
// Serial names the backend + geometry so a black screen stays diagnosable.
fn fbDiag() void {
    var info: fb.Info = undefined;
    if (fb.koruos_fb_info(&info) == 0) {
        koru_say("fbdiag: no framebuffer\n");
        return;
    }
    koru_say("fbdiag: fb "); koru_putdec(info.width); koru_say("x");
    koru_putdec(info.height); koru_say("\n");
    _ = fb.koruos_fb_fill(0, 0, info.width, info.height, 0x00FF0000);
    // step-2 triangle: quarter the px calls so 1080p stays quick
    var y: u32 = 0;
    while (y < info.height) : (y += 2) {
        const half = y;
        var x: u32 = 0;
        while (x < half and x < info.width) : (x += 2)
            _ = fb.koruos_fb_px(x, y, 0x0000FF00);
    }
    koru_say("fbdiag: painted\n");
}

// DIAG: flood the adopted fb with a stage colour — last colour on screen
// names the furthest init completed. comp may clear earlier marks; the
// post-comp marks are what localise a hang in the comp→prog path.
fn stageMark(rgb: u32) void {
    var info: fb.Info = undefined;
    if (fb.koruos_fb_info(&info) != 0)
        _ = fb.koruos_fb_fill(0, 0, info.width, info.height, rgb);
}

// DIAG text console — fb.init adopted the surface; render text and echo
// polled keys. Skips comp/aspace/prog/user.run entirely: no IRQs, no
// task runtime, just ports + pixels. noreturn.
fn textConsole() noreturn {
    koru_say("console: enter\n");
    text.init();
    koru_say("console: init ret\n");
    koru_say("console: text init done\n");
    text.puts("KORU OS - native text console\n");
    koru_say("console: banner1\n");
    text.puts("linear fb up - type to echo\n\n");
    koru_say("console: banner2\n");
    text.puts("> ");
    while (true) {
        if (kbd.pollChar()) |c| {
            if (c == '\n') {
                text.newline();
                text.puts("> ");
            } else {
                text.putc(c);
            }
        }
        // NOT hlt — IF=0 here (no user.init/sti), so hlt halts the CPU
        // forever on the first iteration and the poll loop never runs.
        asm volatile ("pause");
    }
}

var fullBoot: bool = false; // DIAG: false = fbDiag/console fast path; true = real program
var consoleMode: bool = true; // DIAG: true = text console after fb.init

export fn kmain(mbi: u32) callconv(.c) noreturn {
    faults.install();    // IDT FIRST — any later fault FREEZES, never resets
    pmm.init(mbi);       // frames live before anything allocates
    earlyfb.init(mbi);   // adopt GRUB fb via PROVEN mmio.map + draw S0 banner;
                         // AFTER pmm (mmio.map needs pmm.alloc), BEFORE net —
                         // brackets the real-HW NIC fault window
    net.init();          // NIC + UDP telemetry — the display-independent oracle;
                         // runs before every stage that can die blind
    earlyfb.stage(1, "nic-ok");   // NIC armed — KORU markers now reach the listener
    text.udpMirror = net.mirror; // every console line streams to the listener
    const doFull = blk: {
        var v = fullBoot;
        asm volatile ("" : [v] "+r" (v)); // opaque — keeps the branch + inits live
        break :blk v;
    };
    if (doFull) {
        acpi.init(mbi); // RSDP + table directory — MADT/FACP names resolved
        pci.init();  // config-space scan while IF=0 — the dump can't
                     // interleave with IRQ prints; providers look up, never
                     // rescan
        ioapic.init(); // GSI routes armed (masked) — every later unmask
                       // takes the LAPIC door; PIC lines masked for good
        user.init(); // IDT + PIC + sti — interrupts live before the program
        kbd.init();  // 8042 drain + IRQ1 — input events queue from here on
        mouse.init(); // 8042 aux channel — PS/2 mouse, IRQ12
        smp.init();  // INIT-SIPI-SIPI — APs ack + park before userland runs
    }
    fb.init(mbi);
    // i915 modeset is gated behind the shell 'i915' command — the proven
    // console proves kernel+text first; typing it bounds any crash to
    // i915 entry and the last console line names the stage.
    net.mark("fb-init");
    if (consoleMode) { net.mark("shell"); shell.run(); } // DIAG — noreturn
    if (!doFull) { // DIAG fast path only — real boot continues below
        fbDiag();
        while (true) asm volatile ("hlt");
    }
    stageMark(0x00FF0000); // DIAG red — fb adopted, entering comp
    net.mark("comp-init");
    comp.init(); // nativeCompositor — owns the scanout's scene from here
    stageMark(0x0000FF00); // DIAG green — comp.init returned
    net.mark("comp-done");
    aspace.selftest();
    stageMark(0x0000FFFF); // DIAG cyan — aspace done
    net.mark("aspace-done");
    prog.main();
    net.mark("prog-main");
    user.run();
    while (true) asm volatile ("hlt");
}

const std = @import("std");
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    led.crash();
    koru_say("!! PANIC\n");
    if (text.dims().w != 0) {
        text.puts("!! PANIC\n");
        var i: usize = 0;
        while (i < msg.len and i < 48) : (i += 1) text.putc(msg[i]);
        text.newline();
        text.puts("(frozen — no reset)\n");
    }
    while (true) asm volatile ("cli\n\thlt");
}
