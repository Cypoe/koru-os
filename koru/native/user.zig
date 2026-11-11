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
const ioapic = @import("ioapic");
const smp = @import("smp");

extern var pml4: [512]u64;
extern var pdpt: [512]u64;

extern var stdout: ?*anyopaque;
extern fn fputs(s: [*:0]const u8, st: ?*anyopaque) callconv(.c) c_int;
extern fn posix_memalign(memptr: *?*anyopaque, alignment: usize, size: usize) callconv(.c) c_int;
extern fn malloc(size: usize) ?*anyopaque;
extern fn free(ptr: ?*anyopaque) void;
const pmm = @import("pmm");
const kbd = @import("kbd");
extern fn serPut(c: u8) callconv(.c) void;
extern fn ukplat_monotonic_clock() callconv(.c) u64;
extern fn koruos_surface_open(w: u32, h: u32, title: [*:0]const u8) callconv(.c) ?*anyopaque;
extern fn koruos_surface_blit(p: ?*anyopaque, dx: u32, dy: u32, w: u32, h: u32, src: [*]const u32, src_stride: u32) callconv(.c) u8;
extern fn koruos_surface_present(p: ?*anyopaque, x: u32, y: u32, w: u32, h: u32) callconv(.c) u8;
extern fn koruos_surface_move(p: ?*anyopaque, nx: u32, ny: u32) callconv(.c) u8;
extern fn koruos_surface_geom(p: ?*anyopaque, out: *SurfGeom) callconv(.c) u8;
extern fn koruos_surface_map(p: ?*anyopaque, out_phys: *u64, out_bytes: *u64) callconv(.c) u8;
extern fn koruos_surface_close(p: ?*anyopaque) callconv(.c) u8;
extern fn koruos_input_poll(out: *InEv) callconv(.c) u8;
extern fn koruos_input_pending() callconv(.c) u8;

const SurfGeom = extern struct { x: u32, y: u32, w: u32, h: u32, sw: u32, sh: u32 };
const InEv = extern struct { kind: u32, code: u32, pressed: u32, dx: i32, dy: i32 };

// IRQ-time hook: an input event landed in a provider ring — prod any
// child parked on .input (kbd.feedByte/mouse.push call this; the wake
// is mark-only, the parked read re-decides).
pub export fn koru_input_wake() callconv(.c) void {
    wakeKind(.input);
}

const ENT: u64 = 0x3; // present | writable
const US: u64 = 0x4; // user-accessible

// Child user space is its own pdpt slot — [USER_VA_BASE, USER_VA_END)
// maps through c.upd, kept entirely clear of the shared kernel half
// the ISR still needs on the child's CR3. Real ET_EXEC vaddrs below
// 0x40000000 therefore refuse by name: the honest answer is static-pie
// (ET_DYN) or a link above the identity region.
const USER_VA_BASE: usize = 0x4000_0000; // pdpt[1] -> upd -> user pages
const USER_VA_END: usize = 0x7FE0_0000;  // ~1 GiB of user space
const USER_STACK_TOP: usize = 0x7FE0_0000; // stack pages map just below
const USER_STACK_PAGES: usize = 16;
const MMAP_BASE: usize = 0x6000_0000; // mmap arena — between image and stack
const INTERP_BASE: usize = 0x7000_0000; // PT_INTERP loader's ET_DYN bias — clear of mains AND the mmap arena

// VGA text-mode mirror: under CSM/SeaBIOS the firmware leaves 80x25
// text mode active (no gfxterm in our grub.cfg), so 0xB8000 stays
// writable for the whole boot — serial-less hardware gets the same
// log on screen. Scrolls like a terminal; stops writing past the
// last row rather than wrapping into garbage.
var vga_row: usize = 0;
var vga_col: usize = 0;

fn vga_scroll() void {
    const vga: [*]volatile u16 = @ptrFromInt(0xB8000);
    var r: usize = 1;
    while (r < 25) : (r += 1) {
        var c: usize = 0;
        while (c < 80) : (c += 1) vga[(r - 1) * 80 + c] = vga[r * 80 + c];
    }
    r = 24 * 80;
    while (r < 25 * 80) : (r += 1) vga[r] = (@as(u16, 0x07) << 8) | ' ';
}

fn vga_putc(c: u8) void {
    const vga: [*]volatile u16 = @ptrFromInt(0xB8000);
    if (c == '\n') {
        vga_col = 0;
        vga_row += 1;
    } else if (c != '\r') {
        if (vga_col >= 80) {
            vga_col = 0;
            vga_row += 1;
        }
        if (vga_row < 25) {
            vga[vga_row * 80 + vga_col] = (@as(u16, 0x07) << 8) | c;
            vga_col += 1;
        }
    }
    if (vga_row >= 25) {
        vga_scroll();
        vga_row = 24;
    }
}

fn say(s: [*:0]const u8) void {
    _ = fputs(s, stdout);
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) vga_putc(s[i]);
}

fn sayU32Hex(v: u32) void {
    var b: [9]u8 = undefined;
    const digs = "0123456789abcdef";
    var i: usize = 8;
    var x: u32 = v;
    while (i > 0) : (i -= 1) {
        b[i - 1] = digs[x & 15];
        x >>= 4;
    }
    b[8] = 0;
    say(@ptrCast(&b));
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
// gdt2 mirrors the boot GDT then adds user data/code + one 128-bit TSS
// descriptor PER CPU (slot 5+2*cpu, selector 0x28+16*cpu) — a ring
// transition reads the *running* CPU's task register, so each roster
// member needs its own rsp0 home. The table is shared: every CPU
// lgdt's it; each ltr's only its own slot.
const MAXCPU: usize = 8;
var gdt2: [5 + 2 * MAXCPU + 1]u64 align(8) = .{
    0x0000000000000000,
    0x00AF9A000000FFFF, // 0x08 kernel code64
    0x00CF92000000FFFF, // 0x10 kernel data
    0x00CFF2000000FFFF, // 0x18 user data   (DPL=3)
    0x00AFFA000000FFFF, // 0x20 user code64 (DPL=3, L)
} ++ .{0} ** (2 * MAXCPU + 1); // per-CPU TSS descriptor pairs + pad
var tss: [MAXCPU][104]u8 align(16) = [_][104]u8{[_]u8{0} ** 104} ** MAXCPU;
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

// Per-CPU scheduler stacks: schedLoop is reached standing on a RESUMABLE
// stack — ksched and the tick arrive on a child's kstack, exit on a dead
// one — and the roster may hand that same child to ANOTHER cpu while the
// first is still parked in schedLoop's hlt below its saved block; the
// resumed continuation then writes over the idle cpu's live frames (a
// real ret-into-stack-bytes fault). Hop to the cpu's own stack at entry;
// the residue left on the borrowed stack is dead scratch — rsp0 pushes
// overwrite it top-down on the next trap.
const SSTACK: usize = 16 * 1024;
var sstacks: [MAXCPU][SSTACK]u8 align(16) = undefined;

fn sstackTop() u64 {
    return @intFromPtr(&sstacks[cpuSelf()]) + SSTACK;
}

// Hop to this cpu's sched stack and tail-enter cont (noreturn). Every
// scheduler entry that still stands on a borrowed stack goes through
// here; the hop is idempotent — re-entering resets rsp to the top.
fn schedEnter(cont: *const fn () noreturn) noreturn {
    // Entry ABI parity: a `call`ed body expects rsp ≡ 8 (mod 16) — the
    // top slot doubles as the fake return address.
    const top = sstackTop() - 8;
    asm volatile (
        \\ mov %[top], %%rsp
        \\ jmp *%[cont]
        :
        : [top] "r" (top),
          [cont] "r" (cont)
        : .{ .memory = true });
    unreachable;
}

fn patchTssDesc(cpu: usize) void {
    const base: u64 = @intFromPtr(&tss[cpu]);
    const limit: u64 = 103;
    gdt2[5 + 2 * cpu] = (limit & 0xFFFF) | ((base & 0xFFFFFF) << 16) |
        (0x89 << 40) | (((base >> 24) & 0xFF) << 56);
    gdt2[6 + 2 * cpu] = base >> 32;
}

// The running CPU's identity — its local APIC id. Before the LAPIC is
// mapped (early boot) there is only the BSP: 0.
fn cpuSelf() usize {
    if (!lapicArmed) return 0;
    const id = lapic[0x20 / 4] >> 24;
    return if (id < MAXCPU) id else 0;
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
    if (ioapic.gsiFor(irq)) |gsi| {
        ioapic.setMasked(gsi, false);
        return;
    }
    const port: u16 = if (irq < 8) 0x21 else 0xA1;
    const bit: u3 = @intCast(irq & 7);
    outb(port, inb(port) & ~(@as(u8, 1) << bit));
    // a slave line only reaches the CPU through master's cascade input 2
    if (irq >= 8) outb(0x21, inb(0x21) & ~@as(u8, 4));
}

// The line's delivery door decides the EOI: IOAPIC-routed lines are
// LAPIC-delivered (the LAPIC EOI is also the IOAPIC's remote-IRR clear);
// PIC lines keep the 8259 pair. Both arms call this — schedPreempt's
// early EOI included — so the choice can't drift.
fn eoiVec(vec: u64) void {
    if (vec >= 0x30) { // LAPIC-local / MSI door — the LAPIC EOI is the door
        lapicEoi();
        return;
    }
    const l = vec - 0x20;
    if (l < 16 and ioapic.isLapic(@intCast(l))) {
        lapicEoi();
    } else {
        picEoi(vec);
    }
}

pub export var irq_ticks: u64 = 0;
var virtio_seen: u64 = 0;

// virtio.zig exports these once the device is found; 0xFF = unconfigured.
extern var virtio_irq_line: u8;
extern fn virtio_irq_ack() void;

// mouse.zig's IRQ thunk — 8042 aux channel (PS/2 mouse), vec 0x2C.
extern fn mouse_irq() void;

// i915/kms.zig's vblank IRQ thunk — gen8+ display vblank on the i915
// PCI intline (T590: IRQ11 -> vec 0x2B, IOAPIC/LAPIC-delivered). The
// line var stays 0xFF until 'vbirq3' arms the whole chain, so this arm
// is inert before then and stray vec-0x2B deliveries still report+mask
// through the unclaimed path.
extern var i915_vb_irq_line: u8;
extern fn i915_vblank_irq() void;

// i915/kms.zig's MSI vector — the display interrupt's message-signaled
// door (T590: no reachable IO-APIC, edge-only PIC can't carry level
// INTx; MSI writes the LAPIC directly). 0xFF until 'vbirq' arms it.
extern var i915_msi_vec: u8;

// gpu.zig exports these once MSI-X is armed; 0xFF = unconfigured. The
// device's used-ring retirements arrive as the LAPIC vector, not a
// PIC line — the arm below EOI's the LAPIC and wakes the .gpu park.
extern var gpu_msix_vec: u8;
extern var gpu_msix_seen: u64;
extern fn gpu_irq_ack() void;

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
    eoiVec(f.vec);
    tick_armed = true;
    // Hop off the ticked child's kstack BEFORE releasing the claim: the
    // kick wakes a designee that may immediately resume this very slot.
    schedEnter(&schedPreemptTail);
}

fn schedPreemptTail() noreturn {
    releaseExec(); // the stolen frame is a free claim now — kick the field
    schedLoop();
}

export fn irq_exc_dispatch(f: *ExcFrame) callconv(.c) void {
    // Nested arm: the interrupt landed on a cpu that already holds bkl — a
    // device wait inside a body briefly re-enabled IF. The arm's work is
    // bounded (ack, mark, EOI) and safe on the holder's stack; re-locking
    // would spin on the holder's own lock and deadlock the cpu.
    const nested = bklMine();
    if (!nested) lockBkl();
    if (f.vec >= 0x20 and f.vec < 0x30) {
        if (f.vec == 0x20) {
            irq_ticks += 1;
            if (irq_ticks == 1) say("irq: timer delivered\n");
            wakeKind(.poll); // deadline re-check — the tick is poll's clock
            schedPreempt(f);
        } else if (f.vec == 0x21) {
            kbd.irq(); // 8042 scancode → input ring
            // a landed ASCII byte is worth a conin wake; a bare break
            // code is not — the resumed read would just re-block.
            if (kbd.conPending()) wakeKind(.conin);
        } else if (f.vec == 0x2C) {
            mouse_irq(); // 8042 aux channel — PS/2 mouse packet byte
        } else if (virtio_irq_line != 0xFF and f.vec == 0x20 + @as(u64, virtio_irq_line)) {
            virtio_irq_ack();
            virtio_seen += 1;
            if (virtio_seen == 1) say("irq: virtio delivered\n");
            wakeKind(.blk); // a retired request resumes its parked trap
        } else if (i915_vb_irq_line != 0xFF and
            f.vec == 0x20 + @as(u64, i915_vb_irq_line))
        {
            i915_vblank_irq(); // gen8+ vblank — MMIO W1C ack inside; no wake
        } else {
            // unclaimed line: report once, then mask it at the PIC so a
            // level-asserted storm can't drown the boot (PS/2 aux fires
            // IRQ12 on QEMU despite the IMR — masking stops delivery)
            say("irq: stray vec=");
            puthex(f.vec);
            say(" (masked)\n");
            const l: u8 = @intCast(f.vec - 0x20);
            if (ioapic.gsiFor(l)) |gsi| {
                ioapic.setMasked(gsi, true);
            } else {
                const port: u16 = if (l < 8) 0x21 else 0xA1;
                const bit: u3 = @intCast(l & 7);
                outb(port, inb(port) | (@as(u8, 1) << bit));
            }
        }
        eoiVec(f.vec);
        kickHolder();
        if (!nested) unlockBkl();
        return;
    }
    if (f.vec >= 0x30) {
        // LAPIC-local + message-signaled: the timer LVT is per-CPU
        // hardware (each AP's own tick — roster substrate), RESCHED is
        // the claim kick, MSI is the device writing the vector. All
        // take the LAPIC EOI.
        if (f.vec == smp.TIMER_VEC) {
            smp.lapicTick();
            schedPreempt(f); // a tick on an AP holding user code rotates too
        } else if (f.vec == smp.RESCHED_VEC) {
            smp.reschedSeen += 1; // pure wake — schedLoop's next poll is the work
        } else if (i915_msi_vec != 0xFF and f.vec == i915_msi_vec) {
            i915_vblank_irq(); // gen8+ display IRQ via MSI — MMIO ack inside
        } else if (gpu_msix_vec != 0xFF and f.vec == gpu_msix_vec) {
            gpu_irq_ack();
            gpu_msix_seen += 1;
            if (gpu_msix_seen == 1) say("irq: vgpu msix delivered\n");
            wakeKind(.gpu); // a retired command resumes its parked trap
        } else {
            say("irq: stray msi vec=");
            puthex(f.vec);
            say("\n");
        }
        lapicEoi();
        kickHolder();
        if (!nested) unlockBkl();
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
        if (!nested) unlockBkl();
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
// rest push a dummy err first), 0x20-0x2F are IRQ lines, 0x30-0x3F are
// reserved for message-signaled interrupts (MSI/MSI-X — the device
// writes its own vector, no PIC involved). All land on one common entry.
// The rsp parity at stub entry is NOT fixed (CPL0 vs CPL3 sources push
// different frame sizes), so the common entry force-aligns with AND
// before calling into Zig — a fixed sub would be wrong half the time
// (the lesson of three movaps GPFs).
comptime {
    @setEvalBranchQuota(400000);
    var src: []const u8 = ".section .text\n";
    const errv = [_]u8{ 8, 10, 11, 12, 13, 14, 17, 21, 29, 30 };
    for (0..64) |v| {
        var has_err = false;
        for (errv) |e| has_err = has_err or e == v;
        src = src ++ std.fmt.comptimePrint("irqstub_{d}:\n", .{v});
        if (!has_err) src = src ++ "  push $0\n";
        src = src ++ std.fmt.comptimePrint("  push ${d}\n  jmp irq_exc_common\n", .{v});
    }
    // a link-time address table — stub encodings stay free to vary
    src = src ++ ".section .rodata\n.globl irqstub_table\n.align 8\nirqstub_table:\n";
    for (0..64) |v| src = src ++ std.fmt.comptimePrint("  .quad irqstub_{d}\n", .{v});
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

extern var irqstub_table: [64]u64;

// ---- LAPIC: the MSI/MSI-X target -----------------------------------------
// Message-signaled interrupts bypass the PIC entirely — the device writes
// a message to 0xFEE00000 naming the IDT vector, and the EOI goes to the
// LAPIC's own EOI register (0xFEE000B0), never to the 8259. One page of
// MMIO, identity-mapped; software-enabled via the spurious vector reg.
const mmio = @import("mmio");
var lapic: [*]volatile u32 = undefined;
var lapicArmed = false;

fn lapicInit() void {
    if (!mmio.map(0xFEE00000, 0x1000)) return;
    lapic = @ptrFromInt(0xFEE00000);
    lapic[0xF0 / 4] = lapic[0xF0 / 4] | 0x1FF; // software enable + spurious 0xFF
    lapicArmed = true;
}
fn lapicEoi() void {
    lapic[0xB0 / 4] = 0;
}

// Called once from kmain, before the program runs: PIC remapped, every
// gate populated, interrupts on.
pub fn init() void {
    picInit();
    lapicInit();
    // v3 must be DPL=3 — #BP is raised by int3 from user code and the
    // DPL check applies
    for (0..64) |v| setIdtGate(v, irqstub_table[v], v == 3);
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

fn loadGdt2() void {
    var gdt_ptr: [10]u8 align(2) = undefined;
    gdt_ptr[0] = gdt2.len * 8 - 1;
    gdt_ptr[1] = 0;
    const gbase: u64 = @intFromPtr(&gdt2);
    inline for (0..8) |i| gdt_ptr[2 + i] = @intCast((gbase >> (8 * i)) & 0xFF);
    asm volatile ("lgdt (%[p])"
        :
        : [p] "r" (&gdt_ptr),
        : .{ .memory = true });
}

fn loadTables() void {
    loadGdt2();
    const cpu = cpuSelf();
    patchTssDesc(cpu);
    const sel: u16 = @intCast(0x28 + 16 * cpu); // ltr the RUNNING cpu's
    asm volatile (                             // slot — a spawn caller that
        \\ movw $0x10, %ax                    // migrated here on a drain
        \\ movw %ax, %ds                      // escape owns its own TSS,
        \\ movw %ax, %es                      // not cpu0's
        \\ movw %ax, %ss
        \\ ltr %[s]
        :
        : [s] "r" (sel)
        : .{ .memory = true, .rax = true }); // rax clobber: %ax is asm
                                              // scratch — undeclared, the
                                              // allocator put sel in ax and
                                              // ltr loaded 0x10 (ReleaseSmall)
    const rsp0: u64 = @intFromPtr(&kstack) + kstack.len;
    @memcpy(tss[cpu][4..12], std.mem.asBytes(&rsp0)); // TSS.rsp0 — byte
                                                    // offset 4, no align trick

    loadIdt();
    enableSyscall();
}

// Full per-CPU arming — an AP lgdt's the shared gdt2 (user segs + every
// CPU's TSS), ltr's only ITS OWN TSS slot (a ring transition reads the
// running CPU's task register — per-CPU rsp0 lives there), lidt's the
// shared IDT, and programs the SYSCALL MSRs (per-CPU state). After this
// the AP can run a child end-to-end: trap, syscall, preempt, resume.
export fn koru_ap_arm() callconv(.c) void {
    const cpu = cpuSelf();
    patchTssDesc(cpu);
    loadGdt2();
    const sel: u16 = @intCast(0x28 + 16 * cpu);
    asm volatile (
        \\ movw $0x10, %ax
        \\ movw %ax, %ds
        \\ movw %ax, %es
        \\ movw %ax, %ss
        \\ ltr %[s]
        :
        : [s] "r" (sel)
        : .{ .memory = true, .rax = true }); // same ax-scratch clobber as
                                              // loadTables — sel must not
                                              // share ax with the 0x10 loads
    {
        const rsp0: u64 = @intFromPtr(&kstack) + kstack.len;
        @memcpy(tss[cpu][4..12], std.mem.asBytes(&rsp0));
    }
    loadIdt();
    enableSyscall();
}

fn loadIdt() void {
    setIdtGate(0x80, @intFromPtr(&ring3_entry80), true);
    var idt_ptr: [10]u8 align(2) = undefined;
    idt_ptr[0] = 0xFF;
    idt_ptr[1] = 0xFF;
    const ibase: u64 = @intFromPtr(&idt);
    inline for (0..8) |i| idt_ptr[2 + i] = @intCast((ibase >> (8 * i)) & 0xFF);
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&idt_ptr),
        : .{ .memory = true });
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
    // mkdir(path): mint a dir inode and land the leaf in the parent —
    // a distinct verb, never open+O_CREAT wearing a dir.
    mkdir: *const fn (ctx: ?*anyopaque, path: [*:0]const u8) callconv(.c) i64,
    // rmdir(path): remove an EMPTY directory name — the only door for
    // dir removal; unlink on a dir stays EISDIR.
    rmdir: *const fn (ctx: ?*anyopaque, path: [*:0]const u8) callconv(.c) i64,
    // link(old, new): a second name on the SAME inode — nlink counts
    // the names; the object dies when the count reaches zero.
    link: *const fn (ctx: ?*anyopaque, old: [*:0]const u8, new: [*:0]const u8) callconv(.c) i64,
    // mknod(path): mint a special inode — this rung only S_IFSOCK —
    // and return its object key. A unix socket's name IS the node;
    // connect resolves the same key through key().
    mknod: *const fn (ctx: ?*anyopaque, path: [*:0]const u8) callconv(.c) i64,
    // stat_path(path): stat WITHOUT a handle — path-stats ride it, and
    // it's the only way to see objects open() refuses (directories,
    // socket nodes). Mode comes off the inode, never synthesized.
    stat_path: *const fn (ctx: ?*anyopaque, path: [*:0]const u8, dst: [*]u8) callconv(.c) i64,
};

const WaitKind = enum { none, conin, blk, exit, pipe, gpu, sock, blkq, poll, input, efd };

// fd slots are projections over typed seam endpoints, not bare provider
// handles: stdio are real entries (conin/conout), fs a view handle,
// pipe_r/pipe_w ends of a kernel ring. read/write/close dispatch on the
// kind, never on the number — closing fd0 detaches like any discharge.
const FdKind = enum { none, conin, conout, fs, pipe_r, pipe_w, sock, shm, slisten, surf, input, epoll, efd, tfd, sfd };

// ---- signals: queueable kernel facts, not interruptions -------------------
// This arm delivers NO asynchronous invocation — a handler registered
// through rt_sigaction fires never (the stored-metadata ruling stands).
// A signal is a pending fact on the child; the ONLY consumer shape is the
// signalfd projection, which is exactly what wl_event_loop_add_signal
// wants: the event loop eats the fact as bytes. SIGCHLD is the first
// honest producer — a real kernel event (child death) lands on the
// spawner's queue. A second instance of a pending signo merges, newest
// payload wins — the coalescing posix grants non-RT signals; a merged
// signo still reports even if the queue was full (payload zeroed).
const NSIGQ = 8;
const SigEnt = struct { signo: u8 = 0, code: i16 = 0, pid: u32 = 0, status: i32 = 0 };
const SIGCHLD: u8 = 17;
const CLD_EXITED: i16 = 1;
const NO_PARENT: usize = ~@as(usize, 0);

// Enqueue a pending fact. Same-signo merges (the bit stays, payload
// refreshes); an unseen signo on a full queue still marks the bit — the
// read side reports it with a zeroed payload, fact preserved.
fn sigQueue(c: *Child, e: SigEnt) void {
    const bit = @as(u64, 1) << @intCast(e.signo - 1);
    var i: usize = 0;
    while (i < c.nsigs) : (i += 1) {
        if (c.sigs[i].signo == e.signo) {
            c.sigs[i] = e;
            c.sig_pending |= bit;
            return;
        }
    }
    c.sig_pending |= bit;
    if (c.nsigs < NSIGQ) {
        c.sigs[c.nsigs] = e;
        c.nsigs += 1;
    }
}

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
    upd: usize = 0,  // user-half pd — pdpt[1], USER_VA_BASE..END
                     // (kernel half shares pdpt slots with the BSP —
                     //  no per-child kernel tables to own)
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
    fds: [32]u64 = .{0} ** 32,      // endpoint id by kind: fs handle or pipe idx
    fdkinds: [32]FdKind = .{.none} ** 32,
    fdverbs: [32]u8 = .{0} ** 32,   // the fd IS a grant — V_READ/V_WRITE
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
    spawned_by: usize = NO_PARENT,  // spawner's roster slot — the SIGCHLD
                                    // destination; NO_PARENT names the
                                    // boot/root children nobody spawned
    sig_blocked: u64 = 0,           // rt_sigprocmask's stored set — real
                                    // state now: the loop's promise to
                                    // consume via signalfd, recorded
    sig_pending: u64 = 0,           // bitmask of queued signos
    sigs: [NSIGQ]SigEnt = .{SigEnt{}} ** NSIGQ, // per-signo payload queue
    nsigs: u8 = 0,
};

var children: [MAXCHILDREN]Child = .{ .{}, .{}, .{}, .{} };
var nchildren: usize = 0;
var cur_child: usize = 0;
// Exported: the spawn save-asm opens the epoch with `movb $1` only after
// saved_rip exists — the flag is the claim gate, so it must be a symbol.
pub export var sched_active: bool = false;
pub export var sched_switches: u64 = 0;
pub export var kctx_resumes: u64 = 0;
pub export var tick_kctx: u64 = 0;
pub export var forks: u64 = 0;      // nr57 fork calls served
pub export var fork_pages: u64 = 0; // user pages the copies moved
// schedPreempt arms this before entering schedLoop; switchInto consumes
// it — the first dispatch after a tick is tick-driven by construction.
var tick_armed: bool = false;

// ---- roster lock + the running CPU ----------------------------------------
// bkl: every kernel body (ISR dispatch, syscall gate) runs under it — the
// children/pipe/roster state has exactly one writer at a time on ANY cpu.
// Holding it implies IF=0 (lockBkl clis) — a nested IRQ on the holder's own
// cpu must never spin on the lock it already owns. Release points: the
// body's return edge, the exec hand-off (releaseExec), and the user-resume
// arm of switchInto — user code holds NO lock; the kctx-resume arm keeps
// it, since the popped continuation returns INTO a body that expects it.
// bkl holds owner+1 (0 = free) — the owner id is what lets a nested IRQ on
// the holder's own cpu run WITHOUT re-locking: holding bkl implies IF=0 at
// the body level, but a wait inside the body (virtio's sti;hlt) re-enables
// delivery briefly, and the dispatch MUST recognize "I already hold it"
// rather than spin on its own hold. CAS-expecting-0, never Xchg — an Xchg
// clobbers the owner id while spinning, which would make the true holder's
// nested IRQ fail the owner check and deadlock on itself.
var bkl: u32 = 0;

fn lockBkl() void {
    asm volatile ("cli" ::: .{ .memory = true });
    const me: u32 = @intCast(cpuSelf() + 1);
    while (@cmpxchgStrong(u32, &bkl, 0, me, .seq_cst, .seq_cst) != null) {
        asm volatile ("pause");
    }
}
fn unlockBkl() void {
    @atomicStore(u32, &bkl, 0, .seq_cst);
}
// Is the running cpu the bkl holder? The IRQ dispatch's nested arm — the
// interrupt lands while the body holds the lock (a wait briefly re-enabled
// IF); its work is a bounded mark + EOI on the holder's own stack.
fn bklMine() bool {
    const me: u32 = @intCast(cpuSelf() + 1);
    return @atomicLoad(u32, &bkl, .seq_cst) == me;
}

// A device IRQ landed on THIS cpu while another cpu holds bkl — the
// holder may be hlt-parked mid device wait (parkOnce) where only its
// own LAPIC tick would wake it. A resched IPI is a pure wake: the
// holder's hlt exits, its poll re-reads the now-advanced used ring.
fn kickHolder() void {
    const v = @atomicLoad(u32, &bkl, .seq_cst);
    if (v != 0 and v - 1 != cpuSelf()) smp.kickCpu(v - 1);
}

// exec_cpu: the ONE cpu licensed to hold a child in user space (-1 = free).
// Single-runner is the honest roster contract of this rung: the seam's
// ring-transition globals (rsp0_val, child_ursp) name THE running child,
// so at most one exists at a time — claimed under bkl in schedLoop,
// released when it blocks/exits/preempts. A child migrates between cpus
// only across those boundaries. exec_hint is the designated NEXT claimant
// (rotation, not a race — the releasing cpu kicks it by resched-IPI);
// dissolving the singleton needs per-CPU user state (swapgs) — later cell.
var exec_cpu: i32 = -1;
var exec_hint: u32 = 0;

// The running CPU's license to hold a child in user space lapses — it
// blocked, exited, or got ticked. Free the claim, IPI the designated next
// claimant out of its hlt, and drop the lock; the caller then enters
// schedLoop or escapes the drained epoch.
fn releaseExec() void {
    exec_cpu = -1;
    unlockBkl();
    if (smp.rosterHas(exec_hint)) smp.kickCpu(exec_hint);
}

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
    for ([_]u64{ c.upd, c.pdpt, c.pml4 }) |t| {
        if (t != 0) {
            _ = pmm.free(t);
            freed += 1;
        }
    }
    c.upd = 0;
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

// Map an EXISTING frame into a child PT — the shared-map path. pmm.pin
// makes the page co-owned: the child's munmap/exit frees decrement, the
// owner object's ref keeps it alive until the last unmap.
fn mapUserPhys(c: *Child, vaddr: usize, phys: u64) bool {
    if (vaddr < USER_VA_BASE or vaddr >= USER_VA_END) return false;
    const upd: *[512]u64 = @ptrFromInt(c.upd);
    const pd_i = (vaddr - USER_VA_BASE) >> 21;
    if (upd[pd_i] & 1 == 0) {
        const npt = allocPage() orelse return false;
        upd[pd_i] = @intFromPtr(npt) | US | ENT;
    }
    const pt: *[512]u64 = @ptrFromInt(@as(usize, @intCast(upd[pd_i] & ~@as(u64, 0xFFF))));
    const idx = (vaddr >> 12) & 0x1FF;
    if (pt[idx] & 1 != 0) {
        // Replacing a live mapping: drop the old frame's ref first —
        // MAP_FIXED over a populated page is legal and must not leak.
        _ = pmm.free(pt[idx] & ~@as(u64, 0xFFF));
    }
    if (!pmm.pin(phys)) return false;
    pt[idx] = phys | US | ENT;
    return true;
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
    c.upd = @intFromPtr(allocPage() orelse return false);
    const c_pml4: *[512]u64 = @ptrFromInt(c.pml4);
    const c_pdpt: *[512]u64 = @ptrFromInt(c.pdpt);
    // The kernel half is shared, not snapshot: the child's pdpt copies
    // the kernel's own entries, so every mmio window minted at boot
    // (LAPIC/IOAPIC/BARs — all live above 1 GiB) exists on the child's
    // CR3 by construction, and later mappings in an existing slot
    // propagate since the pd is shared. Kernel leaves lack U/S at the
    // leaf, so the shared half stays ring0-only — which is also what
    // lets the ISR run on a child's CR3 without losing itself.
    // pdpt[1] is the child-private user window; a kernel window already
    // occupying it is an unresolvable overlap — refuse by name.
    if (pdpt[1] != 0) {
        say("aspace: kernel window occupies pdpt[1] — child space refused\n");
        return false;
    }
    c_pml4[0] = c.pdpt | US | ENT;
    c_pdpt.* = pdpt;
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

// Blit-path copy with runtime safety off: userEntry gates every byte on
// a present PTE, so the inlined @ptrFromInt null/align checks are
// redundant noise — and they were implicated in an unexplained ud2.
noinline fn copyChunk(c: *Child, va: usize, dst: [*]u8, len: usize) usize {
    @setRuntimeSafety(false);
    var n: usize = 0;
    while (n < len) : (n += 1) {
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
        // rename(82)/renameat(264)/renameat2(316), unlink(87)/unlinkat(263),
        // mkdir(83)/mkdirat(258), rmdir(84), link(86)/linkat(265).
        // The class bit grants mount-wide; object grants narrow them by
        // verb — the mutated object is always a directory's key.
        85, 82, 264, 316, 87, 263, 83, 258, 84, 86, 265 => 2,
        231 => 60,
        318 => 61,
        158, 218, 273, 302 => 62,
        14 => 62, // rt_sigprocmask — proc-self metadata; the stored set
                  // is now real state (signalfd consumes the queue)
        13 => 62, // rt_sigaction — registration is metadata too; a handler
                  // stored where nothing can deliver it fires exactly never
        72 => 62, // fcntl folds to the proc-self group — our handles carry no flag state
        32, 33, 292 => 62, // dup family — fd-table ops on own handles
        228 => 62, // clock_gettime — a self-time query, same describe class
        186 => 39, // gettid folds to getpid — one thread per child exists
        // koru's own ABI lives at 512+, out of musl's namespace — nr57 is
        // REAL fork now (musl _Fork sends it with zero args); clone(56)
        // folds to the same "create a child" cap — the flag-shape refusal
        // is the arm's job, not the bag's. Bits 57/58 name the caps.
        56 => 57,
        512 => 57,
        513 => 58,
        514 => 2, // openobj — the object axis' open; folds to the fs-object
                  // class and the key argument IS the object it names
        77 => 2,  // ftruncate mutates an object's shape — same class
        // IPC-channel class: socketpair and the message verbs ride the
        // pipe cap (a channel is a channel); memfd mints the object the
        // channel carries — same family. The endpoint verbs — socket,
        // bind, listen, accept(+4), connect — are the channel's
        // namespace half: same class, the name is an fs object the arm
        // resolves. poll/ppoll multiplex those same channels — the
        // class question is "may this child wait on channels".
        41, 42, 43, 288, 46, 47, 49, 50, 53, 319, 7, 271 => 22,
        55 => 22, // getsockopt — a channel-fact query on the same class
        // epoll is the same class: an interest list is another way to
        // wait on channels — create/ctl/wait share the bit.
        213, 232, 233, 281, 291 => 22,
        // eventfd is a counted channel — same "wait on channels" class;
        // libwayland-server's terminate semaphore is one.
        284, 290 => 22,
        // timerfd is the same class: a time-shaped channel whose only
        // readiness source is the tick — create/settime/gettime share
        // the bit. wl_event_loop_add_timer rides it (wlr_output frame
        // scheduling, seat repeat).
        283, 286, 287 => 22,
        // signalfd is the same class again: the pending-signal queue is
        // a channel — wl_event_loop_add_signal rides it.
        282, 289 => 22,
        // fchmod mutates an object's mode bits — same class as
        // ftruncate's shape mutation.
        91 => 2,
        // flock is an advisory-lock verb ON an fs object — same class.
        // wl_socket_lock's /wayland-N.lock contention check rides it.
        73 => 2,
        // stat/lstat query an fs object by path — the same class's
        // read half (fstat already rides the fd it names).
        4, 6 => 2,
        // access family — an fs-object permission query; same class.
        21, 269, 439 => 2,
        // scene class (bit 59): a child minting a display surface is a
        // compositor's cap, not a client's — mint/blit/present/move/info
        // ride one bag bit; close is ordinary fd lifetime.
        515, 516, 517, 519, 520 => 59,
        // input class (bit 55): draining the machine's input rings is
        // the compositor's second cap — a client never reads /dev/input.
        518 => 55,
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
    // /dev/shm/<name> is the POSIX shm namespace, not an fs path — the
    // intercept runs before the fs grant check entirely.
    if (shmPathName(p)) |nm| return childShmOpen(c, nm, flags);
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

// Path-stat (nr4 stat / nr6 lstat — no symlink layer exists, so the
// two verbs honestly coincide): the provider's stat_path names the
// inode directly — directories and socket nodes included, neither of
// which open() will mint a handle for. ENOENT propagates; mode is the
// inode's own.
fn childStatPath(c: *Child, pva: usize, stva: u64) i64 {
    const ops = c.fsv orelse return -38;
    var pb: [256]u8 = undefined;
    const p = userPath(c, pva, &pb) orelse return -14;
    pb[p.len] = 0;
    var st: [144]u8 = std.mem.zeroes([144]u8);
    const r = ops.stat_path(ops.ctx, @ptrCast(&pb), &st);
    if (r < 0) return r;
    const n = copyToUser(c, @intCast(stva), &st);
    return if (n < 144) -14 else 0;
}

// access/faccessat/faccessat2 (nr21/269/439): a permission query, not a
// handle. No uid model exists — every child is its own authority — so
// the honest check is DAC-root semantics: R_OK/W_OK grant on an extant
// object (the fs is rw), X_OK requires an x bit set, ENOENT and friends
// propagate. flags beyond AT_EACCESS|AT_SYMLINK_NOFOLLOW refuse EINVAL —
// AT_EMPTY_PATH and the dirfd-relative forms aren't armed, honestly.
fn childAccess(c: *Child, pva: usize, mode: u64, flags: u64) i64 {
    if (mode & ~@as(u64, 7) != 0) return -22; // EINVAL — RWX only
    if (flags & ~@as(u64, 0x300) != 0) return -22;
    const ops = c.fsv orelse return -38;
    var pb: [256]u8 = undefined;
    const p = userPath(c, pva, &pb) orelse return -14;
    pb[p.len] = 0;
    var st: [144]u8 = std.mem.zeroes([144]u8);
    const r = ops.stat_path(ops.ctx, @ptrCast(&pb), &st);
    if (r < 0) return r;
    if (mode & 1 != 0) { // X_OK — root still needs a real x bit
        var m: u32 = 0;
        for (0..4) |i| m |= @as(u32, st[24 + i]) << @intCast(i * 8);
        if (m & 0o111 == 0) return -13; // EACCES
    }
    return 0;
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
    if (shmPathName(p)) |nm| return childShmUnlink(nm);
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

// mkdir/rmdir: single-name dir verbs — the mutated object is the PARENT
// directory, exactly the unlink grant shape. rmdir is its own verb on
// purpose: unlink on a dir is EISDIR, and a non-empty dir is ENOTEMPTY.
fn childMkdir(c: *Child, pva: usize) i64 {
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
            say("SEAM REFUSE mkdir dir-obj=");
            puthex(@bitCast(dk));
            say(" (no W grant)\n");
            return -13;
        }
    }
    return ops.mkdir(ops.ctx, @ptrCast(&pb));
}

fn childRmdir(c: *Child, pva: usize) i64 {
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
            say("SEAM REFUSE rmdir dir-obj=");
            puthex(@bitCast(dk));
            say(" (no W grant)\n");
            return -13;
        }
    }
    return ops.rmdir(ops.ctx, @ptrCast(&pb));
}

// link: a second name on an existing inode. The mutation lands in the
// NEW path's parent dir — the old path is only resolved, never
// mutated, so the grant check covers the destination directory alone.
fn childLink(c: *Child, ova: usize, nva: usize) i64 {
    const ops = c.fsv orelse return -38;
    var ob: [256]u8 = undefined;
    var nb: [256]u8 = undefined;
    const op = userPath(c, ova, &ob) orelse return -14;
    const np = userPath(c, nva, &nb) orelse return -14;
    ob[op.len] = 0;
    nb[np.len] = 0;
    if ((c.rights >> 2) & 1 == 0) {
        var db: [256]u8 = undefined;
        const dp = parentPath(np, &db);
        db[dp.len] = 0;
        const dk = ops.key(ops.ctx, @ptrCast(&db));
        if (dk < 0) return dk;
        if (!grantCovers(c, 2, @bitCast(dk), V_WRITE)) {
            say("SEAM REFUSE link dir-obj=");
            puthex(@bitCast(dk));
            say(" (no W grant)\n");
            return -13;
        }
    }
    return ops.link(ops.ctx, @ptrCast(&ob), @ptrCast(&nb));
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
    if (off & 0xFFF != 0) return -22; // EINVAL — file offset must be page-aligned
    if (fdu >= c.fds.len) return -9;
    const fd: usize = @intCast(fdu);
    if (fd < 3 or c.fds[fd] == 0) return -9; // EBADF
    if (c.fdkinds[fd] == .shm) return childMmapShm(c, addru, len, prot, flags, fd, off);
    if (c.fdkinds[fd] == .surf) return childMmapSurf(c, addru, len, prot, flags, fd, off);
    if (c.fdkinds[fd] != .fs) return -9; // sockets/pipes have no mapping
    const ops = c.fsv orelse return -38;
    if (flags & 0x01 != 0 and prot & 2 != 0) return -95; // EOPNOTSUPP — writable
        // shared maps need write-through; read-only MAP_SHARED is honest: every
        // mapper reads the same provider bytes at map time anyway.
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

// mmap a memfd: MAP_SHARED maps the object's frames into this child's
// PT — the same physical pages every other mapper sees, which IS the
// wl_shm contract. MAP_PRIVATE on shm is CoW we don't implement —
// refused loudly, not silently private.
fn childMmapShm(c: *Child, addru: u64, len: usize, prot: u64, flags: u64, fd: usize, off: u64) i64 {
    const s = &shms[@intCast(c.fds[fd] - 1)];
    if (flags & 0x01 == 0) return -95; // EOPNOTSUPP — private maps need CoW
    // PROT_WRITE|SHARED on a read-only projection is the fd-verb
    // question again: O_RDONLY shm pairs exist for this exact refusal.
    if (prot & 2 != 0 and c.fdverbs[fd] & V_WRITE == 0) return -13;
    var base: usize = 0;
    if (flags & 0x10 != 0 and addru != 0) {
        base = @intCast(addru);
        if (base & 0xFFF != 0 or base < USER_VA_BASE or base + len > USER_VA_END) return -22;
    } else {
        base = c.mmap_top;
        c.mmap_top += (len + 0xFFF) & ~@as(usize, 0xFFF);
    }
    var p: usize = 0;
    while (p < len) : (p += 0x1000) {
        const pi = (off + p) >> 12;
        if (pi >= s.npages) return -22; // past the object — honest EINVAL
        if (!mapUserPhys(c, base + p, s.frames[pi])) return -12;
    }
    setUserWritable(c, base, len, prot & 2 != 0);
    shm_maps += 1;
    return @intCast(base);
}

// mmap a surface: the provider answers whether its retained backing is
// directly projectable — koruos_surface_map hands the contiguous frames
// or refuses (a GPU-resident backing on another arm would say no, and
// the blit verb stays the honest path). MAP_SHARED only: the backing IS
// shared by definition — a private map would be a copy that silently
// diverges from the scene, the same CoW ruling shm carries. Lifetime:
// the pmm pin model holds — each mapped page is co-owned, so a map that
// outlives the fd's close keeps the frames alive but orphaned (the
// layer is already detached); exit's walk drops the refs like shm's.
fn childMmapSurf(c: *Child, addru: u64, len: usize, prot: u64, flags: u64, fd: usize, off: u64) i64 {
    if (flags & 0x01 == 0) return -95; // EOPNOTSUPP — private on a shared backing
    const tok = surfTok(c, fd) orelse return -9;
    var phys: u64 = 0;
    var bytes: u64 = 0;
    if (koruos_surface_map(tok, &phys, &bytes) == 0) return -19; // ENODEV
    if (off >= bytes) return -22; // past the backing — honest EINVAL
    const avail = @min(len, @as(usize, @intCast(bytes - off)));
    var base: usize = 0;
    if (flags & 0x10 != 0 and addru != 0) {
        base = @intCast(addru);
        if (base & 0xFFF != 0 or base < USER_VA_BASE or base + len > USER_VA_END) return -22;
    } else {
        base = c.mmap_top;
        c.mmap_top += (len + 0xFFF) & ~@as(usize, 0xFFF);
    }
    var p: usize = 0;
    while (p < avail) : (p += 0x1000) {
        if (!mapUserPhys(c, base + p, phys + off + p)) return -12;
    }
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
        .sock, .slisten => {
            // S_IFSOCK|0600 — musl's socket probing names it correctly
            stw(&st, 24, 0o140600);
            stw(&st, 16, 1);
        },
        .shm => {
            // S_IFREG|mode — a file-shaped object whose mode fchmod
            // actually writes (the shm pair's RW-lockdown uses it)
            stw(&st, 24, 0o100000 | shms[@intCast(c.fds[fd] - 1)].mode);
            stw(&st, 16, 1);
            stw(&st, 48, shms[@intCast(c.fds[fd] - 1)].size); // st_size
        },
        .surf => {
            // a display surface is a handle on the scene, not a byte
            // channel — chrdev 0600 names it honestly
            stw(&st, 24, 0o20600);
            stw(&st, 16, 1);
        },
        .input => {
            // an input reader is a char device — the evdev answer
            stw(&st, 24, 0o20600);
            stw(&st, 16, 1);
        },
        .epoll, .efd, .tfd, .sfd => {
            // interest list, counter, clock, and signal queue are all
            // anonymous — linux fstat calls them S_IFIFO|0600
            // (anon_inode); same answer
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
        // Check-under-lock then park: the byte must not land between the
        // drain's empty verdict and the blocked mark, or nobody wakes us.
        // bkl IS the mask — the whole trap body holds it.
        if (!kbd.conPending()) {
            kblock(.conin); // returns re-holding bkl — a wake happened
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
            if (n != 0) {
                pipe_reads += 1;
                wakePipe(idx); // space opened — prod any parked writer
                return @intCast(n);
            }
            if (userEntry(c, @intCast(buva)) & 1 == 0) return -14;
        } else if (p.wrefs == 0) {
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
        if (p.rrefs == 0) {
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

// ---- unix sockets: two rings + an fd-ref queue per direction ----------
// A SOCK_STREAM pair is a pair of kernel rings (bytes each way) PLUS the
// ancillary channel real unix semantics demand: SCM_RIGHTS fd passing —
// sendmsg dups the sender's fd into the direction's queue NOW (the fd
// survives the sender closing it), recvmsg installs queued refs into the
// receiver's table under a real cmsghdr. Wayland's wl_shm protocol is
// the load-bearing consumer: a pool fd crosses the socket, the server
// mmaps it, and the buffer's frames are genuinely shared. The wait key
// is .sock + wait_pipe = pair*2+dir — mark-only wakes like every kind.
const NSOCKS = 4;
const SOCKQ = 8; // queued fd refs per direction — a bound, like the ring
const FdRef = struct { kind: FdKind = .none, h: u64 = 0, verbs: u8 = 0 };
const SockDir = struct {
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    buf: [2048]u8 = undefined,
    q: [SOCKQ]FdRef = .{FdRef{}} ** SOCKQ,
    qn: u8 = 0,
};
const SockPair = struct {
    used: bool = false,
    dir: [2]SockDir = .{ .{}, .{} }, // dir[s]: readable on side s
    refs: [2]u8 = .{ 0, 0 },
    conn: bool = false, // socket() mints unconnected — I/O is ENOTCONN
    owner: [2]u32 = .{ 0, 0 }, // roster slot+1 of each side's minter —
                             // SO_PEERCRED's honest answer
};
var socks: [NSOCKS]SockPair = .{SockPair{}} ** NSOCKS;

// A listening unix socket: the NAME lives in the fs view (a real
// S_IFSOCK inode minted by ops.mknod — connect resolves it through
// key()), the registry maps (view, object key) → this entry, and the
// backlog is a pending-projection queue: pair ends minted by connect,
// waiting for accept to install them into an fd table.
const NLISTEN = 4;
const SOKPEND = 8;
const ACCEPT_KEY = 0x100; // wait_pipe subkey base — past pair*2+dir space
const SockListener = struct {
    used: bool = false,
    live: bool = false,     // listen() ran — connect refuses before it
    fsv_ctx: usize = 0,     // ops.ctx — the view identity half of the key
    key: u64 = 0,           // dev<<32|ino — the socket node's object key
    refs: u8 = 0,
    pend: [SOKPEND]u8 = .{0} ** SOKPEND, // pair*2+side+1 of queued ends
    npend: u8 = 0,
};
var listeners: [NLISTEN]SockListener = .{SockListener{}} ** NLISTEN;

fn wakeListen(lidx: usize) void {
    for (0..nchildren) |i| {
        const p = &children[i];
        if (p.state == .blocked and p.wait_kind == .sock and
            p.wait_pipe == ACCEPT_KEY + lidx) p.state = .runnable;
    }
}

// Drop an fd/queue-held projection of the listener. At refs==0 the
// registry entry dies with it: pending session ends close (their
// clients see the peer leave) and any parked connect/accept wakes to
// re-check — a dead listener is ECONNREFUSED/EINVAL, not a hang.
fn listenerRelease(lidx: usize) void {
    const l = &listeners[lidx];
    if (l.refs > 0) l.refs -= 1;
    if (l.refs != 0) return;
    while (l.npend > 0) {
        l.npend -= 1;
        const v = l.pend[l.npend] - 1;
        sockCloseEnd(v >> 1, v & 1);
    }
    l.* = .{};
    wakeListen(lidx);
}
pub export var sock_sends: u64 = 0;
pub export var sock_recvs: u64 = 0;
pub export var sock_fdpass: u64 = 0;

fn wakeSock(pair: usize, dir: usize) void {
    const key = pair * 2 + dir;
    for (0..nchildren) |i| {
        const p = &children[i];
        if (p.state == .blocked and p.wait_kind == .sock and
            p.wait_pipe == key) p.state = .runnable;
    }
}

fn sockPairCreate(conn: bool) ?usize {
    for (0..NSOCKS) |i| {
        if (!socks[i].used) {
            socks[i] = .{ .used = true, .refs = .{ 1, 1 }, .conn = conn };
            return i;
        }
    }
    return null;
}

// Dup a live fd entry for transfer: bump the endpoint's refs and return
// the queued-ref record. fs goes through the provider dup (shared-offset
// POSIX semantics, same as cloneFd). false = undupable kind.
fn fdDupRef(c: *Child, fd: usize, out: *FdRef) bool {
    const kind = c.fdkinds[fd];
    switch (kind) {
        .pipe_r => pipes[@intCast(c.fds[fd])].rrefs += 1,
        .pipe_w => pipes[@intCast(c.fds[fd])].wrefs += 1,
        .sock => {
            const v = c.fds[fd] - 1;
            socks[@intCast(v >> 1)].refs[@intCast(v & 1)] += 1;
        },
        .slisten => listeners[@intCast(c.fds[fd] - 1)].refs += 1,
        .shm => shms[@intCast(c.fds[fd] - 1)].refs += 1,
        .surf => surfs[@intCast(c.fds[fd] - 1)].refs += 1,
        .input => ins[@intCast(c.fds[fd] - 1)] += 1,
        .epoll => epolls[@intCast(c.fds[fd] - 1)].refs += 1,
        .efd => efds[@intCast(c.fds[fd] - 1)].refs += 1,
        .tfd => tfds[@intCast(c.fds[fd] - 1)].refs += 1,
        .fs => {
            const ops = c.fsv orelse return false;
            const nh = ops.dup(ops.ctx, c.fds[fd]);
            if (nh < 0) return false;
            out.* = .{ .kind = kind, .h = @intCast(nh), .verbs = c.fdverbs[fd] };
            return true;
        },
        else => return false,
    }
    out.* = .{ .kind = kind, .h = c.fds[fd], .verbs = c.fdverbs[fd] };
    return true;
}

// Release one queued/held ref — used when a queued ref dies with the
// pair or a truncated cmsg. The mirror of fdDupRef's arm list.
fn fdFreeRef(r: FdRef) void {
    switch (r.kind) {
        .pipe_r => pipeCloseEnd(@intCast(r.h), .pipe_r),
        .pipe_w => pipeCloseEnd(@intCast(r.h), .pipe_w),
        .sock => sockCloseEnd(@intCast((r.h - 1) >> 1), @intCast((r.h - 1) & 1)),
        .slisten => listenerRelease(@intCast(r.h - 1)),
        .shm => shmRelease(@intCast(r.h - 1)),
        .surf => surfRefFree(@intCast(r.h - 1)),
        .input => inputFree(@intCast(r.h - 1)),
        .epoll => epollFree(@intCast(r.h - 1)),
        .efd => efdFree(@intCast(r.h - 1)),
        .tfd => tfdFree(@intCast(r.h - 1)),
        else => {},
    }
}

fn sockWrite(c: *Child, pair: usize, dir: usize, bva: u64, want: u64, nb: bool) i64 {
    if (want == 0) return 0;
    if (!socks[pair].conn) return -107; // ENOTCONN — socket() before connect
    const d = &socks[pair].dir[dir];
    while (true) {
        if (socks[pair].refs[dir] == 0) return -32; // EPIPE — reader side gone
        var n: usize = 0;
        while (n < want and d.count < d.buf.len) : (n += 1) {
            const va: usize = @intCast(bva + n);
            if (userEntry(c, va) & 1 == 0) break;
            const ub: [*]u8 = @ptrFromInt(userPhys(c, va) + (va & 0xFFF));
            d.buf[d.head] = ub[0];
            d.head = (d.head + 1) % d.buf.len;
            d.count += 1;
        }
        if (n != 0) {
            sock_sends += 1;
            wakeSock(pair, dir); // bytes landed — prod the parked reader
            return @intCast(n);
        }
        if (userEntry(c, @intCast(bva)) & 1 == 0) return -14;
        if (nb) return -11; // MSG_DONTWAIT — EAGAIN, unix's flush answer
        c.wait_pipe = pair * 2 + dir;
        kblock(.sock); // wake = space or the reader leaving
    }
}

fn sockRead(c: *Child, pair: usize, dir: usize, bva: u64, want: u64, nb: bool) i64 {
    if (want == 0) return 0;
    if (!socks[pair].conn) return -107; // ENOTCONN
    const d = &socks[pair].dir[dir];
    while (true) {
        if (d.count > 0) {
            var n: usize = 0;
            while (n < want and d.count > 0) : (n += 1) {
                const va: usize = @intCast(bva + n);
                if (userEntry(c, va) & 1 == 0) break;
                const ub: [*]u8 = @ptrFromInt(userPhys(c, va) + (va & 0xFFF));
                ub[0] = d.buf[d.tail];
                d.tail = (d.tail + 1) % d.buf.len;
                d.count -= 1;
            }
            if (n != 0) {
                sock_recvs += 1;
                wakeSock(pair, dir); // space opened — prod the writer
                return @intCast(n);
            }
            if (userEntry(c, @intCast(bva)) & 1 == 0) return -14;
        } else if (socks[pair].refs[dir ^ 1] == 0) {
            return 0; // peer gone and drained — this read IS the EOS
        } else {
            if (nb) return -11; // MSG_DONTWAIT — EAGAIN, dispatch's empty check
            c.wait_pipe = pair * 2 + dir;
            kblock(.sock); // wake = a byte or the peer leaving
        }
    }
}

fn sockCloseEnd(pair: usize, side: usize) void {
    const s = &socks[pair];
    if (s.refs[side] > 0) s.refs[side] -= 1;
    wakeSock(pair, side ^ 1); // the peer's waiters re-check the refs
    wakeSock(pair, side);
    if (s.refs[0] == 0 and s.refs[1] == 0) {
        // Both ends gone — queued refs die with the pair.
        for (0..2) |d| {
            while (s.dir[d].qn > 0) {
                s.dir[d].qn -= 1;
                fdFreeRef(s.dir[d].q[s.dir[d].qn]);
            }
        }
        s.* = .{};
    }
}

// ---- memfd shm objects: anonymous shared memory that survives close ---
// The object pins its frames; a MAP_SHARED mapper pins each frame again
// into its PT, so the pages outlive every fd and die with the last
// unmap — memfd's real lifetime, which wl_shm's "close the fd after
// sendmsg" idiom depends on.
const NSHM = 16;
// 8 MiB per object — a nested compositor's pixman swapchain buffer is a
// real framebuffer (1280x720x4 ~ 3.5 MiB), not a test tile.
const SHM_MAXPAGES = 2048;
const ShmObj = struct {
    used: bool = false,
    refs: u8 = 0, // live fd handles (each SCM_QUEUED ref counts too)
    npages: u16 = 0, // SHM_MAXPAGES=2048 — u8 silently wrapped at 255
    size: u64 = 0,
    // POSIX shm namespace: a /dev/shm/<name> open carries these — an
    // anonymous memfd is namelen 0. unlink clears the name while the
    // object lives on through refs — real tmpfs unlink semantics.
    name: [48]u8 = .{0} ** 48,
    namelen: u8 = 0,
    mode: u16 = 0o600,
    frames: [SHM_MAXPAGES]u64 = .{0} ** SHM_MAXPAGES,
};
var shms: [NSHM]ShmObj = .{ShmObj{}} ** NSHM;
pub export var shm_maps: u64 = 0;

// ---- scene surfaces: the compositor's door --------------------------------
// surf_open (nr515) mints a *Surf through the provider and projects it
// as a .surf fd — the child's custody rides the fd table, so dup shares
// the token and close()/exit auto-detaches from the scene (the reveal
// repaint is comp.zig's job, not the caller's). surf_blit (nr516) is the
// bulk commit write: a rect of the child's own pixels copied into the
// provider's retained backing, row-bounced through a kernel page.
// surf_present (nr517) is the damage commit through the z-stack.
const NSURF = 8;
const SurfRef = struct {
    tok: ?*anyopaque = null, // the provider's *Surf — never trusted arithmetic
    refs: u32 = 0,
};
var surfs: [NSURF]SurfRef = .{SurfRef{}} ** NSURF;

fn surfRefFree(idx: usize) void {
    const s = &surfs[idx];
    if (s.refs > 0) s.refs -= 1;
    if (s.refs == 0) {
        _ = koruos_surface_close(s.tok);
        s.tok = null;
    }
}

fn childSurfOpen(c: *Child, f: *TrapFrame) i64 {
    const w: u32 = @intCast(f.rdi & 0xFFFFFFFF);
    const h: u32 = @intCast(f.rsi & 0xFFFFFFFF);
    if (w == 0 or h == 0) return -22;
    var fd: ?usize = null;
    for (c.fds, 0..) |v, i| if (v == 0 and c.fdkinds[i] == .none) {
        fd = i;
        break;
    };
    const fdi = fd orelse return -24;
    var slot: ?usize = null;
    for (&surfs, 0..) |*s, i| if (s.refs == 0) {
        slot = i;
        break;
    };
    const si = slot orelse return -24;
    const tok = koruos_surface_open(w, h, "koru-os") orelse return -19; // no display backend — ENODEV
    surfs[si] = .{ .tok = tok, .refs = 1 };
    c.fds[fdi] = si + 1;
    c.fdkinds[fdi] = .surf;
    c.fdverbs[fdi] = 0;
    return @intCast(fdi);
}

fn surfTok(c: *Child, fdu: u64) ?*anyopaque {
    if (fdu >= c.fds.len) return null;
    const fd: usize = @intCast(fdu);
    if (c.fdkinds[fd] != .surf or c.fds[fd] == 0) return null;
    const idx: usize = @intCast(c.fds[fd] - 1);
    if (idx >= NSURF) return null;
    return surfs[idx].tok;
}

// blit(fd, src_va, src_stride_bytes, rect_va) — rect_va points at a
// {dx,dy,w,h}:u32x4 in the child's space (the 6-register ABI means the
// rect rides memory, like iovec does). Rows bounce through one kernel
// page: a stride over the page refuses rather than splitting a row.
fn childSurfBlit(c: *Child, f: *TrapFrame) i64 {
    const tok = surfTok(c, f.rdi) orelse return -9;
    const src_va: usize = @intCast(f.rsi);
    const stride: usize = @intCast(f.rdx);
    var rect: [4]u32 = undefined;
    if (copyFromUser(c, @intCast(f.r10), std.mem.sliceAsBytes(&rect)) < 16) return -14;
    const dx = rect[0];
    const dy = rect[1];
    const w = rect[2];
    const h = rect[3];
    if (w == 0 or h == 0 or @as(usize, w) * 4 > stride or stride > 65536) return -22;
    // A 1280-wide row is 5120 bytes — wider than the bounce page. Rows go
    // in ≤1024-px column chunks: same provider rect contract, arbitrary
    // stride, one page of bounce. Inputs are validated above; the block
    // runs with runtime safety off — the compiler was emitting a bogus
    // 0x1ff bound on (w - cx) that fired on every wide row.
    var y: u32 = 0;
    var ret: i64 = 0;
    blk: {
        @setRuntimeSafety(false);
        while (y < h) : (y += 1) {
            var cx: u32 = 0;
            while (cx < w) : (cx += 1024) {
                const cw = @min(@as(u32, 1024), w - cx);
                const off = src_va + @as(usize, y) * stride + @as(usize, cx) * 4;
                var nb: usize = @as(usize, cw) * 4;
                // The folder mis-optimizes the bounded (w - cx)*4 chain in
                // this loop (observed: `andl $0x7fc` → len=0 for cw=1024).
                // An empty asm barrier keeps nb opaque — the value is what
                // the arithmetic says, not what a wrong range inference
                // decides it must be.
                asm volatile (""
                    : [nb] "+r" (nb),
                );
                if (copyChunk(c, off, &blit_bounce, nb) < nb) {
                    ret = -14;
                    break :blk;
                }
                if (koruos_surface_blit(tok, dx + cx, dy + y, cw, 1,
                    @ptrCast(&blit_bounce), cw) == 0) {
                    ret = -22;
                    break :blk;
                }
            }
        }
    }
    return ret;
}

// Static bounce page for childSurfBlit — the syscall path is
// single-runner (BKL), so one shared page is sound and removes
// alloc/free from the copy loop entirely.
var blit_bounce: [4096]u8 align(4096) = undefined;

fn childSurfPresent(c: *Child, f: *TrapFrame) i64 {
    const tok = surfTok(c, f.rdi) orelse return -9;
    const x: u32 = @intCast(f.rsi & 0xFFFFFFFF);
    const y: u32 = @intCast(f.rdx & 0xFFFFFFFF);
    const w: u32 = @intCast(f.r10 & 0xFFFFFFFF);
    const h: u32 = @intCast(f.r8 & 0xFFFFFFFF);
    if (w == 0 or h == 0) return -22; // commit means damage
    if (koruos_surface_present(tok, x, y, w, h) == 0) return -22;
    return 0;
}

fn childSurfMove(c: *Child, f: *TrapFrame) i64 {
    const tok = surfTok(c, f.rdi) orelse return -9;
    const nx: u32 = @intCast(f.rsi & 0xFFFFFFFF);
    const ny: u32 = @intCast(f.rdx & 0xFFFFFFFF);
    if (koruos_surface_move(tok, nx, ny) == 0) return -22;
    return 0;
}

// info(fd, out_va) — the surface's scene rect + the scene's extent;
// a compositor needs both to hit-test and clamp the pointer.
fn childSurfInfo(c: *Child, f: *TrapFrame) i64 {
    const tok = surfTok(c, f.rdi) orelse return -9;
    var g: SurfGeom = undefined;
    if (koruos_surface_geom(tok, &g) == 0) return -22;
    if (copyToUser(c, @intCast(f.rsi), std.mem.sliceAsBytes((&g)[0..1])) < @sizeOf(SurfGeom)) return -14;
    return 0;
}

// ---- input door: evdev-shaped InEv records off the provider rings ------
// input_open (nr518) mints a reader fd over the seam's event drain —
// the SAME queue koruos_input_poll drains kernel-side, so the
// compositor's cursor fan-out keeps working while a child reads. One
// merged stream, device-separated by InEv.kind (1 key, 2 button,
// 3 motion) — per-device nodes are the /dev/input/ rung, not this one.
const NIN = 4;
var ins: [NIN]u32 = .{0} ** NIN; // refs per open

fn inputFree(idx: usize) void {
    if (ins[idx] > 0) ins[idx] -= 1;
}

fn childInputOpen(c: *Child) i64 {
    var fd: ?usize = null;
    for (c.fds, 0..) |v, i| if (v == 0 and c.fdkinds[i] == .none) {
        fd = i;
        break;
    };
    const fdi = fd orelse return -24;
    for (&ins, 0..) |*r, i| if (r.* == 0) {
        r.* = 1;
        c.fds[fdi] = i + 1;
        c.fdkinds[fdi] = .input;
        c.fdverbs[fdi] = V_READ;
        return @intCast(fdi);
    };
    return -24;
}

// read(inputfd) — drain complete InEv records into the user buffer,
// 20 bytes each; an empty drain parks on .input (IRQ wakes re-decide).
fn childInputRead(c: *Child, f: *TrapFrame) i64 {
    const want: usize = @intCast(f.rdx);
    if (want < @sizeOf(InEv)) return 0;
    const bva: usize = @intCast(f.rsi);
    while (true) {
        var n: usize = 0;
        var ev: InEv = undefined;
        while (n + @sizeOf(InEv) <= want and koruos_input_poll(&ev) != 0) {
            if (copyToUser(c, bva + n, std.mem.sliceAsBytes((&ev)[0..1])) < @sizeOf(InEv)) break;
            n += @sizeOf(InEv);
        }
        if (n != 0) return @intCast(n);
        // pending-before-park is the race guard: an IRQ landing between
        // drain and park leaves the predicate true and we re-drain.
        if (userEntry(c, bva) & 1 == 0) return -14;
        if (koruos_input_pending() == 0) kblock(.input);
    }
}

// nr 213/291 epoll_create(1) / nr 233 epoll_ctl / nr 232 epoll_wait —
// the interest-list shape of the same readiness truth: real event
// loops (libwayland-server's among them) multiplex through epoll, not
// poll. The interest list is kernel-side, per epoll OBJECT (dup and
// SCM share it — an epoll fd is a projection of the list, like every
// other kind); readiness is still fdPollRev evaluated at wait time —
// no cached revents, so a wake is always a re-decision and the .poll
// continuation carries epoll waiters for free.
const NEPOLL = 8;
const EPOLLIN: u16 = 0x1;
const EpollEnt = struct { fdi: u8 = 0, ev: u16 = 0, data: u64 = 0 };
const Epoll = struct {
    refs: u32 = 0,
    nent: u8 = 0,
    ents: [MAXPOLLFDS]EpollEnt = .{EpollEnt{}} ** MAXPOLLFDS,
};
var epolls: [NEPOLL]Epoll = .{Epoll{}} ** NEPOLL;

fn epollFree(idx: usize) void {
    const e = &epolls[idx];
    if (e.refs > 0) e.refs -= 1;
    if (e.refs == 0) e.nent = 0;
}

fn childEpollCreate(c: *Child) i64 {
    var fd: ?usize = null;
    for (c.fds, 0..) |v, i| if (v == 0 and c.fdkinds[i] == .none) {
        fd = i;
        break;
    };
    const fdi = fd orelse return -24;
    for (&epolls, 0..) |*e, i| if (e.refs == 0) {
        e.* = .{ .refs = 1 };
        c.fds[fdi] = i + 1;
        c.fdkinds[fdi] = .epoll;
        c.fdverbs[fdi] = V_READ;
        return @intCast(fdi);
    };
    return -24;
}

// ctl(epfd, op, fd, event) — the interest list's own verbs: ADD(1)
// registers (fd,events,data), MOD(2) rewrites, DEL(3) drops. The
// event struct is linux's packed {u32 events, u64 data} = 12 bytes.
// Self-add is EINVAL like linux; an .epoll TARGET is lawful nesting
// (the readiness scan depth-caps, it does not loop).
fn childEpollCtl(c: *Child, epfdu: u64, op: u64, fdu: u64, evva: u64) i64 {
    if (epfdu >= c.fds.len or fdu >= c.fds.len) return -9;
    const epidx: usize = @intCast(c.fds[@intCast(epfdu)] - 1);
    if (c.fdkinds[@intCast(epfdu)] != .epoll) return -22;
    const fdi: usize = @intCast(fdu);
    if (c.fdkinds[fdi] == .none) return -9;
    if (epfdu == fdu) return -22; // epfd in its own list — linux EINVAL
    const e = &epolls[epidx];
    if (op == 3) { // DEL — event ptr may be NULL
        var i: usize = 0;
        while (i < e.nent) : (i += 1) {
            if (e.ents[i].fdi == fdi) {
                e.nent -= 1;
                e.ents[i] = e.ents[e.nent];
                return 0;
            }
        }
        return -2; // ENOENT
    }
    if (op != 1 and op != 2) return -22;
    var evb: [12]u8 = undefined;
    if (copyFromUser(c, @intCast(evva), &evb) < 12) return -14;
    const ev = std.mem.readInt(u32, evb[0..4], .little);
    const data = std.mem.readInt(u64, evb[4..12], .little);
    if (op == 1) { // ADD
        var i: usize = 0;
        while (i < e.nent) : (i += 1)
            if (e.ents[i].fdi == fdi) return -17; // EEXIST
        if (e.nent >= MAXPOLLFDS) return -28; // ENOSPC
        e.ents[e.nent] = .{ .fdi = @intCast(fdi), .ev = @intCast(ev), .data = data };
        e.nent += 1;
        return 0;
    }
    // MOD — must exist
    var i: usize = 0;
    while (i < e.nent) : (i += 1) {
        if (e.ents[i].fdi == fdi) {
            e.ents[i].ev = @intCast(ev);
            e.ents[i].data = data;
            return 0;
        }
    }
    return -2;
}

// Readiness of an epoll object = any interest entry that would fire —
// depth-capped because epoll may legally nest (ELOOP lives at depth).
fn epollReady(c: *Child, idx: usize, depth: u4) bool {
    if (depth >= 5) return false;
    const e = &epolls[idx];
    var i: usize = 0;
    while (i < e.nent) : (i += 1) {
        const t = e.ents[i].fdi;
        if (c.fdkinds[t] == .epoll) {
            if (epollReady(c, @intCast(c.fds[t] - 1), depth + 1)) return true;
        } else if (fdPollRev(c, t, e.ents[i].ev) != 0) return true;
    }
    return false;
}

// epoll_wait(epfd, events, maxevents, timeout_ms) — same shape as
// childPoll: a scan, a deadline, a .poll continuation between them.
fn childEpollWait(c: *Child, epfdu: u64, evva: u64, maxev: u64, tmo: i64) i64 {
    if (epfdu >= c.fds.len or c.fdkinds[@intCast(epfdu)] != .epoll) return -9;
    if (maxev == 0 or maxev > MAXPOLLFDS) return -22;
    const e = &epolls[@intCast(c.fds[@intCast(epfdu)] - 1)];
    const deadline: u64 = if (tmo < 0) std.math.maxInt(u64)
        else irq_ticks + pollDeadlineTicks(tmo);
    while (true) {
        var n: i64 = 0;
        var i: usize = 0;
        while (i < e.nent and n < @as(i64, @intCast(maxev))) : (i += 1) {
            const rev = fdPollRev(c, e.ents[i].fdi, e.ents[i].ev);
            if (rev != 0) {
                var eb: [12]u8 = undefined;
                std.mem.writeInt(u32, eb[0..4], rev, .little);
                std.mem.writeInt(u64, eb[4..12], e.ents[i].data, .little);
                if (copyToUser(c, @intCast(evva + @as(u64, @intCast(n)) * 12), &eb) < 12) return -14;
                n += 1;
            }
        }
        if (n != 0) return n;
        if (irq_ticks >= deadline) return 0;
        kblock(.poll);
    }
}

// nr 284/290 eventfd(2) — a counted semaphore as an fd: read drains
// (or decrements under EFD_SEMAPHORE), write accumulates; readiness
// is counter!=0. libwayland-server's wl_display_create mints one as
// its terminate_efd — the loop's wakeup channel for wl_display_terminate.
const NEFD = 8;
const EFD_MAX: u64 = 0xFFFFFFFFFFFFFFFE;
const Efd = struct {
    refs: u32 = 0,
    val: u64 = 0,
    nonblock: u8 = 0,
    sem: u8 = 0,
};
var efds: [NEFD]Efd = .{Efd{}} ** NEFD;

fn efdFree(idx: usize) void {
    const e = &efds[idx];
    if (e.refs > 0) e.refs -= 1;
    if (e.refs == 0) e.* = .{};
}

fn childEventfd(c: *Child, initval: u64, flags: u64) i64 {
    // EFD_SEMAPHORE=0x1, EFD_NONBLOCK=0x800, EFD_CLOEXEC=0x80000 —
    // cloexec rides no flag state here (the fcntl fold's ruling); any
    // other bit refuses by name.
    if (flags & ~@as(u64, 0x80801) != 0) {
        say("SEAM REFUSE eventfd flags=");
        puthex(flags);
        say(" (unknown bits)\n");
        return -22;
    }
    var fd: ?usize = null;
    for (c.fds, 0..) |v, i| if (v == 0 and c.fdkinds[i] == .none) {
        fd = i;
        break;
    };
    const fdi = fd orelse return -24;
    for (&efds, 0..) |*e, i| if (e.refs == 0) {
        e.* = .{ .refs = 1, .val = initval,
                 .nonblock = @intFromBool(flags & 0x800 != 0),
                 .sem = @intFromBool(flags & 1 != 0) };
        c.fds[fdi] = i + 1;
        c.fdkinds[fdi] = .efd;
        c.fdverbs[fdi] = V_READ | V_WRITE;
        return @intCast(fdi);
    };
    return -24;
}

fn childEfdRead(c: *Child, f: *TrapFrame) i64 {
    if (f.rdx < 8) return -22; // EINVAL — a counter read is one u64
    const e = &efds[@intCast(c.fds[@intCast(f.rdi)] - 1)];
    while (true) {
        if (e.val != 0) {
            var eb: [8]u8 = undefined;
            std.mem.writeInt(u64, &eb, if (e.sem != 0) 1 else e.val, .little);
            if (copyToUser(c, @intCast(f.rsi), &eb) < 8) return -14;
            if (e.sem != 0) e.val -= 1 else e.val = 0;
            return 8;
        }
        if (e.nonblock != 0) return -11; // EAGAIN
        if (userEntry(c, @intCast(f.rsi)) & 1 == 0) return -14;
        kblock(.efd);
    }
}

fn childEfdWrite(c: *Child, f: *TrapFrame) i64 {
    if (f.rdx < 8) return -22;
    var eb: [8]u8 = undefined;
    if (copyFromUser(c, @intCast(f.rsi), &eb) < 8) return -14;
    const add = std.mem.readInt(u64, &eb, .little);
    if (add == 0xFFFFFFFFFFFFFFFF) return -22; // linux refuses the max
    const e = &efds[@intCast(c.fds[@intCast(f.rdi)] - 1)];
    while (true) {
        if (add <= EFD_MAX - e.val) {
            e.val += add;
            wakeKind(.efd);
            return 8;
        }
        if (e.nonblock != 0) return -11;
        kblock(.efd);
    }
}

// nr 283/286/287 timerfd_create/settime/gettime — a time-shaped channel:
// read yields a u64 expiry count, readiness is count!=0. There is no
// interrupt side to pump — irq_ticks is the only wall clock, so
// expirations accrue lazily at query time (read/poll/ready), and a
// blocked reader parks on .poll, which the tick already wakes.
// Quantization is the PIT/LAPIC tick (~55ms) — the same granularity
// every deadline in the seam states honestly.
const NTFD = 8;
const TFD_TICK_NS: u64 = 55_000_000; // the tick's nominal wall time
const Tfd = struct {
    refs: u32 = 0,
    nonblock: u8 = 0,
    next: u64 = std.math.maxInt(u64), // tick of next expiry; max = disarmed
    iticks: u64 = 0,                  // period in ticks; 0 = one-shot
    count: u64 = 0,                   // expirations not yet read
};
var tfds: [NTFD]Tfd = .{Tfd{}} ** NTFD;

fn tfdFree(idx: usize) void {
    const t = &tfds[idx];
    if (t.refs > 0) t.refs -= 1;
    if (t.refs == 0) t.* = .{};
}

// ns → ticks, ceiling — the deadline quantum, same rule as poll's.
fn tfdTicks(ns: u64) u64 {
    if (ns == 0) return 0;
    return (ns + TFD_TICK_NS - 1) / TFD_TICK_NS;
}

// Accrue whatever the clock already earned. Repeating timers lap: a
// slow reader sees the COUNT, not just the lateness — linux semantics.
fn tfdPump(t: *Tfd) void {
    if (t.next == std.math.maxInt(u64)) return;
    while (irq_ticks >= t.next) {
        t.count +|= 1;
        if (t.iticks == 0) {
            t.next = std.math.maxInt(u64);
            break;
        }
        t.next += t.iticks;
    }
}

fn childTimerfdCreate(c: *Child, clockid: u64, flags: u64) i64 {
    // CLOCK_REALTIME=0 / CLOCK_MONOTONIC=1 share the tick — there is no
    // second wall clock to distinguish them by; anything else refuses.
    if (clockid > 1) {
        say("SEAM REFUSE timerfd clock=");
        puthex(clockid);
        say(" (only boot/monotonic exist)\n");
        return -22;
    }
    if (flags & ~@as(u64, 0x80800) != 0) {
        say("SEAM REFUSE timerfd flags=");
        puthex(flags);
        say(" (unknown bits)\n");
        return -22;
    }
    var fd: ?usize = null;
    for (c.fds, 0..) |v, i| if (v == 0 and c.fdkinds[i] == .none) {
        fd = i;
        break;
    };
    const fdi = fd orelse return -24;
    for (&tfds, 0..) |*t, i| if (t.refs == 0) {
        t.* = .{ .refs = 1, .nonblock = @intFromBool(flags & 0x800 != 0) };
        c.fds[fdi] = i + 1;
        c.fdkinds[fdi] = .tfd;
        c.fdverbs[fdi] = V_READ;
        return @intCast(fdi);
    };
    return -24;
}

// itimerspec on x86_64: {it_value {sec,nsec}, it_interval {sec,nsec}}
// = 4x i64 = 32 bytes. flags bit0 TFD_TIMER_ABSTIME (the value reads
// against the same tick clock), bit1 CANCEL_ON_SET (inert here — the
// clock is never set); anything else refuses.
fn childTimerfdSettime(c: *Child, fdu: u64, flags: u64, newva: u64, oldva: u64) i64 {
    if (fdu >= c.fds.len or c.fdkinds[@intCast(fdu)] != .tfd) return -9;
    if (flags & ~@as(u64, 0x3) != 0) return -22;
    const t = &tfds[@intCast(c.fds[@intCast(fdu)] - 1)];
    tfdPump(t);
    if (oldva != 0) {
        var ob: [32]u8 = std.mem.zeroes([32]u8);
        if (t.next != std.math.maxInt(u64)) {
            const rem = (t.next - irq_ticks) * TFD_TICK_NS;
            std.mem.writeInt(i64, ob[0..8], @intCast(rem / 1_000_000_000), .little);
            std.mem.writeInt(i64, ob[8..16], @intCast(rem % 1_000_000_000), .little);
        }
        const insns = t.iticks * TFD_TICK_NS;
        std.mem.writeInt(i64, ob[16..24], @intCast(insns / 1_000_000_000), .little);
        std.mem.writeInt(i64, ob[24..32], @intCast(insns % 1_000_000_000), .little);
        if (copyToUser(c, @intCast(oldva), &ob) < 32) return -14;
    }
    var nb: [32]u8 = undefined;
    if (copyFromUser(c, @intCast(newva), &nb) < 32) return -14;
    const vsec = std.mem.readInt(i64, nb[0..8], .little);
    const vnsec = std.mem.readInt(i64, nb[8..16], .little);
    const isec = std.mem.readInt(i64, nb[16..24], .little);
    const isnsec = std.mem.readInt(i64, nb[24..32], .little);
    if (vsec < 0 or isec < 0 or
        vnsec < 0 or vnsec >= 1_000_000_000 or
        isnsec < 0 or isnsec >= 1_000_000_000) return -22;
    t.next = std.math.maxInt(u64);
    t.iticks = 0;
    t.count = 0; // re-arm discards unread expirations — linux semantics
    const vns: u64 = @as(u64, @intCast(vsec)) * 1_000_000_000 + @as(u64, @intCast(vnsec));
    const insns: u64 = @as(u64, @intCast(isec)) * 1_000_000_000 + @as(u64, @intCast(isnsec));
    if (vns != 0) {
        t.next = if (flags & 1 != 0) tfdTicks(vns) // absolute tick
            else irq_ticks + @max(tfdTicks(vns), 1);
        t.iticks = tfdTicks(insns);
        tfdPump(t); // an abstime already past expires NOW
    }
    return 0;
}

fn childTimerfdGettime(c: *Child, fdu: u64, curva: u64) i64 {
    if (fdu >= c.fds.len or c.fdkinds[@intCast(fdu)] != .tfd) return -9;
    const t = &tfds[@intCast(c.fds[@intCast(fdu)] - 1)];
    tfdPump(t);
    var ob: [32]u8 = std.mem.zeroes([32]u8);
    if (t.next != std.math.maxInt(u64)) {
        const rem = (t.next - irq_ticks) * TFD_TICK_NS;
        std.mem.writeInt(i64, ob[0..8], @intCast(rem / 1_000_000_000), .little);
        std.mem.writeInt(i64, ob[8..16], @intCast(rem % 1_000_000_000), .little);
    }
    const insns = t.iticks * TFD_TICK_NS;
    std.mem.writeInt(i64, ob[16..24], @intCast(insns / 1_000_000_000), .little);
    std.mem.writeInt(i64, ob[24..32], @intCast(insns % 1_000_000_000), .little);
    return if (copyToUser(c, @intCast(curva), &ob) < 32) -14 else 0;
}

fn childTfdRead(c: *Child, f: *TrapFrame) i64 {
    if (f.rdx < 8) return -22; // a count read is one u64
    const t = &tfds[@intCast(c.fds[@intCast(f.rdi)] - 1)];
    while (true) {
        tfdPump(t);
        if (t.count != 0) {
            var eb: [8]u8 = undefined;
            std.mem.writeInt(u64, &eb, t.count, .little);
            if (copyToUser(c, @intCast(f.rsi), &eb) < 8) return -14;
            t.count = 0;
            return 8;
        }
        if (t.nonblock != 0) return -11;
        kblock(.poll); // the tick is the wake — .poll rides it for free
    }
}

// nr 282/327 signalfd/signalfd4 — a pending-signal queue projected as an
// fd: the object's mask selects which queued facts dequeue as
// signalfd_siginfo bytes. There is no async delivery to race — signalfd
// is the ONLY consumer of pending facts, which is the contract
// wl_event_loop_add_signal was always about. Readiness is
// pending∩mask through fdPollRev; a blocked reader parks on .poll,
// woken by the producer's wakeKind.
const NSFD = 8;
const Sfd = struct {
    refs: u32 = 0,
    mask: u64 = 0,
    nonblock: u8 = 0,
};
var sfds: [NSFD]Sfd = .{Sfd{}} ** NSFD;

fn sfdFree(idx: usize) void {
    const s = &sfds[idx];
    if (s.refs > 0) s.refs -= 1;
    if (s.refs == 0) s.* = .{};
}

// signalfd(fd, mask, flags) — fd -1 mints a projection bound to the
// caller's 8-byte mask; an existing .sfd fd RE-BINDS the mask (linux's
// update verb — the fd is a window on the child's queue, not the queue).
// SFD_NONBLOCK(0x800)/SFD_CLOEXEC(0x80000) are the only legal flags;
// SFD_CLOEXEC rides no state here (the fcntl fold's ruling).
fn childSignalfd(c: *Child, fdu: u64, maskva: u64, flags: u64) i64 {
    if (flags & ~@as(u64, 0x80800) != 0) {
        say("SEAM REFUSE signalfd flags=");
        puthex(flags);
        say(" (unknown bits)\n");
        return -22;
    }
    if (maskva == 0) return -14;
    var mb: [8]u8 = undefined;
    if (copyFromUser(c, @intCast(maskva), &mb) < 8) return -14;
    const mask = std.mem.readInt(u64, &mb, .little);
    if (fdu != NO_PARENT) { // ~0UL — an existing projection re-binds
        if (fdu >= c.fds.len or c.fdkinds[@intCast(fdu)] != .sfd) return -9;
        const s = &sfds[@intCast(c.fds[@intCast(fdu)] - 1)];
        s.mask = mask;
        s.nonblock = @intFromBool(flags & 0x800 != 0); // linux applies
            // the flag word on update — clear counts too
        return @intCast(fdu);
    }
    var fd: ?usize = null;
    for (c.fds, 0..) |v, i| if (v == 0 and c.fdkinds[i] == .none) {
        fd = i;
        break;
    };
    const fdi = fd orelse return -24;
    for (&sfds, 0..) |*s, i| if (s.refs == 0) {
        s.* = .{ .refs = 1, .mask = mask,
                  .nonblock = @intFromBool(flags & 0x800 != 0) };
        c.fds[fdi] = i + 1;
        c.fdkinds[fdi] = .sfd;
        c.fdverbs[fdi] = V_READ;
        return @intCast(fdi);
    };
    return -24;
}

// read — signalfd_siginfo is 128 bytes: a short buffer is EINVAL, a
// longer one drains multiple facts (linux's floor(len/128) rule). A
// pending bit whose payload merged away still reports its signo —
// coalescing loses the detail, never the fact.
fn childSfdRead(c: *Child, f: *TrapFrame) i64 {
    if (f.rdx < 128) return -22;
    const s = &sfds[@intCast(c.fds[@intCast(f.rdi)] - 1)];
    while (true) {
        var out: usize = 0;
        var i: usize = 0;
        while (i < c.nsigs and out + 128 <= f.rdx) {
            const e = c.sigs[i];
            if (s.mask & (@as(u64, 1) << @intCast(e.signo - 1)) == 0) {
                i += 1;
                continue;
            }
            var ib: [128]u8 = std.mem.zeroes([128]u8);
            std.mem.writeInt(u32, ib[0..4], e.signo, .little);    // ssi_signo
            std.mem.writeInt(i32, ib[8..12], e.code, .little);    // ssi_code
            std.mem.writeInt(u32, ib[12..16], e.pid, .little);    // ssi_pid
            std.mem.writeInt(i32, ib[40..44], e.status, .little); // ssi_status
            if (copyToUser(c, @intCast(f.rsi + out), &ib) < 128) return -14;
            out += 128;
            c.sig_pending &= ~(@as(u64, 1) << @intCast(e.signo - 1));
            c.nsigs -= 1;
            c.sigs[i] = c.sigs[c.nsigs]; // compact — re-examine the swap-in
        }
        var bits = c.sig_pending & s.mask;
        while (bits != 0 and out + 128 <= f.rdx) {
            const b: u6 = @intCast(@ctz(bits));
            var ib: [128]u8 = std.mem.zeroes([128]u8);
            std.mem.writeInt(u32, ib[0..4], @as(u32, b) + 1, .little);
            if (copyToUser(c, @intCast(f.rsi + out), &ib) < 128) return -14;
            out += 128;
            c.sig_pending &= ~(@as(u64, 1) << b);
            bits = c.sig_pending & s.mask;
        }
        if (out != 0) return @intCast(out);
        if (s.nonblock != 0) return -11;
        if (userEntry(c, @intCast(f.rsi)) & 1 == 0) return -14;
        kblock(.poll); // a produced fact is a .poll readiness change
    }
}

fn shmRelease(idx: usize) void {
    const s = &shms[idx];
    if (s.refs > 0) s.refs -= 1;
    if (s.refs == 0) {
        for (0..s.npages) |i| {
            if (s.frames[i] != 0) _ = pmm.free(s.frames[i]);
        }
        s.* = .{};
    }
}

fn shmTrunc(idx: usize, len: u64) i64 {
    const s = &shms[idx];
    const np: usize = @intCast((len + 0xFFF) >> 12);
    if (np > SHM_MAXPAGES) return -12;
    while (s.npages < np) : (s.npages += 1) {
        const page = allocPage() orelse return -12;
        s.frames[s.npages] = @intFromPtr(page);
    }
    // shrink keeps the pages — mmap may still point in (real memfd
    // semantics: a truncated-away tail SIGBUSes, we keep it simple)
    s.size = len;
    return 0;
}

// ---- flock: advisory locks on object identity -------------------------
// wl_display_add_socket locks /wayland-N.lock with LOCK_EX|LOCK_NB and a
// second compositor must see EWOULDBLOCK — the contention is REAL, not
// proforma. Locks key on the object (dev<<32|ino out of fstat's st_dev/
// st_ino — the same key the grant layer names) and belong to the open
// file description: dup'd fds share the lock, a fresh open is a stranger.
// Blocking (no LOCK_NB) parks on .poll — the tick re-evaluates, and
// every unlock wakes .poll waiters so a released lock is seen promptly.
const NFLOCK = 16;
const FLock = struct {
    used: bool = false,
    key: u64 = 0,     // dev<<32|ino for .fs, shm-namespaced for .shm
    ofd: u64 = 0,     // open-file-description identity: the fd's handle
    excl: bool = false,
};
var flocks: [NFLOCK]FLock = [_]FLock{.{}} ** NFLOCK;

fn flockKeyOf(c: *Child, fd: usize) i64 {
    switch (c.fdkinds[fd]) {
        .fs => {
            const ops = c.fsv orelse return -38;
            var st: [144]u8 = std.mem.zeroes([144]u8);
            if (ops.stat(ops.ctx, c.fds[fd], &st) < 0) return -9;
            var dev: u64 = 0;
            var ino: u64 = 0;
            for (0..8) |i| {
                dev |= @as(u64, st[i]) << @intCast(i * 8);
                ino |= @as(u64, st[8 + i]) << @intCast(i * 8);
            }
            return @bitCast((dev << 32) | (ino & 0xFFFF_FFFF));
        },
        .shm => return @bitCast(@as(u64, 0xFEED_0000_0000_0000) | c.fds[fd]),
        else => return -9, // EBADF — channels don't flock
    }
}

// The OFD identity the lock belongs to: dup'd fds share the object
// handle (and the lock); a fresh open of the same object is a stranger
// whose handle differs. fs and shm handles share the small-int space —
// the high bit keeps them from colliding as OFDs.
fn ofdOf(c: *Child, i: usize) u64 {
    return switch (c.fdkinds[i]) {
        .fs => c.fds[i],
        .shm => 0x8000_0000_0000_0000 | c.fds[i],
        else => 0xFFFF_0000_0000_0000 | i, // unique, never lockable
    };
}

fn flockDropOfd(key: u64, ofd: u64) void {
    for (&flocks) |*l| {
        if (l.used and l.key == key and l.ofd == ofd) {
            l.* = .{};
            wakeKind(.poll); // a released lock is readiness for waiters
        }
    }
}

// An OFD's locks die only when NO fd of this child still projects it —
// the last close discharges, a dup's first close must not.
fn flockDropIfOrphaned(c: *Child, ofd: u64) void {
    for (0..c.fds.len) |j| {
        if (c.fdkinds[j] != .none and ofdOf(c, j) == ofd) return;
    }
    for (&flocks) |*l| {
        if (l.used and l.ofd == ofd) {
            l.* = .{};
            wakeKind(.poll);
        }
    }
}

fn childFlock(c: *Child, fdu: u64, opu: u64) i64 {
    if (fdu >= c.fds.len) return -9;
    const fd: usize = @intCast(fdu);
    const op: u32 = @intCast(opu);
    const LOCK_SH: u32 = 1;
    const LOCK_EX: u32 = 2;
    const LOCK_NB: u32 = 4;
    const LOCK_UN: u32 = 8;
    if (op & ~(LOCK_SH | LOCK_EX | LOCK_NB | LOCK_UN) != 0) return -22;
    if ((op & LOCK_SH != 0) and (op & LOCK_EX != 0)) return -22;
    const k = flockKeyOf(c, fd);
    if (k < 0) return k;
    const key: u64 = @bitCast(k);
    const ofd = ofdOf(c, fd);
    if (op & LOCK_UN != 0) {
        flockDropOfd(key, ofd);
        return 0; // unlocking an unlocked object still succeeds
    }
    const want_ex = (op & LOCK_EX) != 0;
    while (true) {
        var contend = false;
        for (&flocks) |*l| {
            if (l.used and l.key == key and l.ofd != ofd and
                (l.excl or want_ex)) {
                contend = true;
                break;
            }
        }
        if (!contend) break;
        if (op & LOCK_NB != 0) return -11; // EWOULDBLOCK
        kblock(.poll); // tick + every unlock re-evaluate — same lazy
                       // contract as the poll arm's re-scan
    }
    flockDropOfd(key, ofd); // upgrade/downgrade replaces my own entry
    var slot: ?*FLock = null;
    for (&flocks) |*l| {
        if (!l.used) { slot = l; break; }
    }
    const l = slot orelse return -12; // ENOMEM — table exhausted, loudly
    l.* = .{ .used = true, .key = key, .ofd = ofd, .excl = want_ex };
    return 0;
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
fn releaseFd(c: *Child, i: usize) void {
    const ofd = ofdOf(c, i); // captured before discharge — the lock
                           // on this OFD dies if this was its last fd
    switch (c.fdkinds[i]) {
        .none => {},
        .fs => {
            if (c.fsv) |ops| _ = ops.close(ops.ctx, c.fds[i]);
        },
        .pipe_r, .pipe_w => pipeCloseEnd(@intCast(c.fds[i]), c.fdkinds[i]),
        .sock => sockCloseEnd(@intCast((c.fds[i] - 1) >> 1), @intCast((c.fds[i] - 1) & 1)),
        .slisten => listenerRelease(@intCast(c.fds[i] - 1)),
        .shm => shmRelease(@intCast(c.fds[i] - 1)),
        .surf => surfRefFree(@intCast(c.fds[i] - 1)),
        .input => inputFree(@intCast(c.fds[i] - 1)),
        .epoll => epollFree(@intCast(c.fds[i] - 1)),
        .efd => efdFree(@intCast(c.fds[i] - 1)),
        .tfd => tfdFree(@intCast(c.fds[i] - 1)),
        .sfd => sfdFree(@intCast(c.fds[i] - 1)),
        .conin, .conout => {},
    }
    c.fds[i] = 0;
    c.fdkinds[i] = .none;
    c.fdverbs[i] = 0;
    flockDropIfOrphaned(c, ofd);
}

fn releaseFds(c: *Child) void {
    for (0..c.fds.len) |i| releaseFd(c, i);
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
        .sock => {
            const v = src.fds[sfd] - 1;
            socks[@intCast(v >> 1)].refs[@intCast(v & 1)] += 1;
        },
        .slisten => listeners[@intCast(src.fds[sfd] - 1)].refs += 1,
        .shm => shms[@intCast(src.fds[sfd] - 1)].refs += 1,
        .surf => surfs[@intCast(src.fds[sfd] - 1)].refs += 1,
        .input => ins[@intCast(src.fds[sfd] - 1)] += 1,
        .epoll => epolls[@intCast(src.fds[sfd] - 1)].refs += 1,
        .efd => efds[@intCast(src.fds[sfd] - 1)].refs += 1,
        .tfd => tfds[@intCast(src.fds[sfd] - 1)].refs += 1,
        .sfd => sfds[@intCast(src.fds[sfd] - 1)].refs += 1,
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

// nr 53 — socketpair(AF_UNIX, SOCK_STREAM, 0, sv[2]): mint the pair and
// land both ends in the caller's table. An fd entry's value is
// pair*2+side — side s reads dir[s] and writes dir[1-s].
fn childSocketpair(c: *Child, svva: u64) i64 {
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
    const pi = sockPairCreate(true) orelse return -24;
    socks[pi].owner = .{ @intCast(cur_child + 1), @intCast(cur_child + 1) };
    var out: [8]u8 = undefined;
    for (0..2) |i| std.mem.writeInt(u32, out[i * 4 ..][0..4], @intCast(slots[i]), .little);
    if (copyToUser(c, @intCast(svva), &out) < 8) {
        socks[pi] = .{};
        return -14;
    }
    for (0..2) |i| {
        c.fdkinds[slots[i]] = .sock;
        c.fds[slots[i]] = pi * 2 + i + 1;
        c.fdverbs[slots[i]] = V_READ | V_WRITE;
    }
    return 0;
}

fn sockSlot(c: *Child) ?usize {
    for (0..c.fds.len) |i| {
        if (c.fdkinds[i] == .none) return i;
    }
    return null;
}

// sockaddr_un: {u16 family=AF_UNIX, char path[108]} — NUL-terminated
// or exactly 108 bytes (abstract '\0'-first names are a linux
// namespace this rung does not serve — refused, not mangled).
fn sockPath(c: *Child, ava: u64, alen: u64, out: []u8) ?[]const u8 {
    if (alen < 3 or alen > 110) return null;
    var ab: [110]u8 = undefined;
    if (copyFromUser(c, @intCast(ava), ab[0..@intCast(alen)]) < alen) return null;
    if (std.mem.readInt(u16, ab[0..2], .little) != 1) return null; // AF_UNIX
    const plen: usize = @intCast(alen - 2);
    if (ab[2] == 0) return null; // abstract namespace — not this rung
    const n = std.mem.indexOfScalar(u8, ab[2 .. 2 + plen], 0) orelse plen;
    if (n == 0 or n >= out.len) return null;
    @memcpy(out[0..n], ab[2 .. 2 + n]);
    out[n] = 0;
    return out[0 .. n + 1];
}

// nr 41 — socket(AF_UNIX, SOCK_STREAM, proto): an unconnected end —
// bind makes it a name, connect makes it a session, until then I/O is
// ENOTCONN. SOCK_CLOEXEC/SOCK_NONBLOCK ride the upper type bits and
// are masked like socketpair's (flags are fcntl no-ops here).
fn childSocket(c: *Child, f: *TrapFrame) i64 {
    if (f.rdi != 1 or (f.rsi & 0xF) != 1) return -97; // EAFNOSUPPORT
    const slot = sockSlot(c) orelse return -24; // EMFILE
    const pi = sockPairCreate(false) orelse return -24;
    socks[pi].refs[1] = 0; // no peer until connect grafts a session
    socks[pi].owner[0] = @intCast(cur_child + 1);
    c.fdkinds[slot] = .sock;
    c.fds[slot] = pi * 2 + 1;
    c.fdverbs[slot] = V_READ | V_WRITE;
    return @intCast(slot);
}

// nr 49 — bind(fd, sockaddr_un, len): give the unconnected socket a
// NAME — a real S_IFSOCK inode in the caller's fs view (ops.mknod),
// then the (view, object key) registry entry. The fd becomes the
// listener: it never carries bytes, it hands out sessions.
fn childBind(c: *Child, f: *TrapFrame) i64 {
    if (f.rdi >= c.fds.len) return -9;
    const fd: usize = @intCast(f.rdi);
    if (c.fdkinds[fd] != .sock) return -88; // ENOTSOCK
    const v = c.fds[fd] - 1;
    if (socks[@intCast(v >> 1)].conn) return -22; // EINVAL — already connected
    const ops = c.fsv orelse return -38; // ENOSYS — no view, no name
    var pb: [112]u8 = undefined;
    const path = sockPath(c, f.rsi, f.rdx, &pb) orelse return -22;
    var lidx: ?usize = null;
    for (0..NLISTEN) |i| {
        if (!listeners[i].used) { lidx = i; break; }
    }
    const li = lidx orelse return -24;
    const key = ops.mknod(ops.ctx, @ptrCast(path.ptr));
    if (key < 0) {
        return if (key == -17) -98 // EEXIST → EADDRINUSE, unix's word
        else key;
    }
    // The name took — the unconnected pair's ring was never a session;
    // release it and let the fd project the listener instead.
    sockCloseEnd(@intCast(v >> 1), @intCast(v & 1));
    listeners[li] = .{ .used = true, .fsv_ctx = @intFromPtr(ops.ctx),
                       .key = @bitCast(key), .refs = 1 };
    c.fdkinds[fd] = .slisten;
    c.fds[fd] = li + 1;
    return 0;
}

// nr 50 — listen(fd, backlog): the node's queue opens. connect
// refuses until this runs — a bound-not-listening name is
// ECONNREFUSED, same as unix.
fn childListen(c: *Child, f: *TrapFrame) i64 {
    if (f.rdi >= c.fds.len) return -9;
    const fd: usize = @intCast(f.rdi);
    if (c.fdkinds[fd] != .slisten) return -95; // EOPNOTSUPP
    listeners[@intCast(c.fds[fd] - 1)].live = true;
    return 0;
}

// nr 42 — connect(fd, sockaddr_un, len): resolve the node's object key
// through the REAL fs view (ENOENT for no name, ECONNREFUSED for a
// name with no live listener — the unix distinction), mint the
// session pair, queue the server end on the listener's backlog, and
// re-point this fd at the client end. Blocking backlog: a full queue
// parks on the listener; accept frees a slot and wakes.
fn childConnect(c: *Child, f: *TrapFrame) i64 {
    if (f.rdi >= c.fds.len) return -9;
    const fd: usize = @intCast(f.rdi);
    if (c.fdkinds[fd] != .sock) return -88;
    const v = c.fds[fd] - 1;
    const op: usize = @intCast(v >> 1);
    if (socks[op].conn) return -106; // EISCONN
    const ops = c.fsv orelse return -38;
    var pb: [112]u8 = undefined;
    const path = sockPath(c, f.rsi, f.rdx, &pb) orelse return -22;
    const key = ops.key(ops.ctx, @ptrCast(path.ptr));
    if (key < 0) return if (key == -2) -2 else key; // ENOENT — no name
    var li: ?usize = null;
    for (0..NLISTEN) |i| {
        const l = &listeners[i];
        if (l.used and l.fsv_ctx == @intFromPtr(ops.ctx) and
            l.key == @as(u64, @bitCast(key))) {
            li = i;
            break;
        }
    }
    while (true) {
        const l = li orelse return -111; // ECONNREFUSED — name, no listener
        if (!listeners[l].live) return -111; // bound but not listening
        if (listeners[l].npend < SOKPEND) {
            const npi = sockPairCreate(true) orelse return -24;
            listeners[l].pend[listeners[l].npend] = @intCast(npi * 2 + 1 + 1);
            listeners[l].npend += 1;
            wakeListen(l); // a session waits on accept
            // The unconnected placeholder pair dies; this fd now
            // projects the client end of the queued session.
            sockCloseEnd(op, @intCast(v & 1));
            socks[npi].owner[0] = @intCast(cur_child + 1);
            c.fds[fd] = npi * 2 + 1;
            return 0;
        }
        c.wait_pipe = ACCEPT_KEY + l;
        kblock(.sock); // backlog full — accept frees a slot and wakes
        li = null; // re-resolve: the listener may have died while parked
        for (0..NLISTEN) |i| {
            const l2 = &listeners[i];
            if (l2.used and l2.fsv_ctx == @intFromPtr(ops.ctx) and
                l2.key == @as(u64, @bitCast(key))) {
                li = i;
                break;
            }
        }
    }
}

// nr 43/288 — accept(fd, addr, addrlen[, flags]): pop the oldest
// pending session end into a NEW fd — the socket that actually
// carries the client's bytes. Empty queue parks on the listener;
// a connect queues and wakes.
fn childAccept(c: *Child, f: *TrapFrame) i64 {
    if (f.rdi >= c.fds.len) return -9;
    const fd: usize = @intCast(f.rdi);
    if (c.fdkinds[fd] != .slisten) return -95; // EOPNOTSUPP
    const li: usize = @intCast(c.fds[fd] - 1);
    while (true) {
        const l = &listeners[li];
        if (l.npend > 0) {
            const pv = l.pend[0];
            for (1..l.npend) |i| l.pend[i - 1] = l.pend[i];
            l.npend -= 1;
            wakeListen(li); // a backlog-parked connect retries
            const slot = sockSlot(c) orelse {
                // No table room — re-queue the end, the caller can
                // close something and retry (EMFILE is unix's answer).
                l.pend[l.npend] = pv;
                l.npend += 1;
                return -24;
            };
            const v = pv - 1;
            socks[@intCast(v >> 1)].owner[@intCast(v & 1)] =
                @intCast(cur_child + 1);
            c.fdkinds[slot] = .sock;
            c.fds[slot] = v + 1;
            c.fdverbs[slot] = V_READ | V_WRITE;
            return @intCast(slot);
        }
        c.wait_pipe = ACCEPT_KEY + li;
        kblock(.sock); // wake = a queued session or the listener dying
    }
}

// nr 55 — getsockopt(fd, level, optname, optval, optlen): one fact is
// served — SOL_SOCKET/SO_PEERCRED, the peer identity libwayland-server
// asks for at wl_client_create. ucred is {pid, uid, gid}: one identity
// realm, uid=gid=0, pid is the peer side's minting child's roster id.
// Every other option refuses ENOPROTOOPT — a socket fact we do not
// name is a refusal, not a zero.
fn childGetsockopt(c: *Child, f: *TrapFrame) i64 {
    if (f.rdi >= c.fds.len) return -9;
    const fd: usize = @intCast(f.rdi);
    if (c.fdkinds[fd] != .sock) return -88; // ENOTSOCK
    if (f.rsi != 1 or f.rdx != 17) return -92; // SOL_SOCKET/SO_PEERCRED only
    var lb: [4]u8 = undefined;
    if (copyFromUser(c, @intCast(f.r8), &lb) < 4) return -14;
    if (std.mem.readInt(u32, &lb, .little) < 12) return -22;
    const v = c.fds[fd] - 1;
    const owner = socks[@intCast(v >> 1)].owner[@intCast((v & 1) ^ 1)];
    if (owner == 0) return -22; // no peer minted yet — EINVAL like linux
    var ub: [12]u8 = undefined;
    std.mem.writeInt(i32, ub[0..4], @intCast(owner), .little);
    std.mem.writeInt(u32, ub[4..8], 0, .little);
    std.mem.writeInt(u32, ub[8..12], 0, .little);
    if (copyToUser(c, @intCast(f.r10), &ub) < 12) return -14;
    std.mem.writeInt(u32, &lb, 12, .little);
    if (copyToUser(c, @intCast(f.r8), &lb) < 4) return -14;
    return 0;
}

// nr 7 poll / nr 271 ppoll — readiness multiplexing, not a new wait:
// the parked side is a .poll continuation re-deciding on every wake.
// pollfd: {i32 fd; i16 events; i16 revents} — 8 bytes, nfds capped at
// the table's own bound. Readiness is per-kind truth, not a flag cache:
// a .sock is readable when bytes sit or the peer left (read=EOS), a
// .slisten when the backlog is non-empty, regular objects always.
const POLLIN: u16 = 0x1;
const POLLOUT: u16 = 0x4;
const POLLERR: u16 = 0x8;
const POLLHUP: u16 = 0x10;
const POLLNVAL: u16 = 0x20;
const POLLRDHUP: u16 = 0x2000;
const MAXPOLLFDS = 32;

fn fdPollRev(c: *Child, fdi: usize, ev: u16) u16 {
    if (fdi >= c.fds.len) return POLLNVAL;
    var r: u16 = 0;
    switch (c.fdkinds[fdi]) {
        .conin => {
            if (ev & POLLIN != 0 and kbd.conPending()) r |= POLLIN;
        },
        .conout => {
            if (ev & POLLOUT != 0) r |= POLLOUT;
        },
        // regular objects are always read/write-ready — linux's answer
        // for files; seeking/EOF is the read's own business.
        .fs, .shm => r |= ev & (POLLIN | POLLOUT),
        .pipe_r => {
            const p = &pipes[@intCast(c.fds[fdi])];
            if (ev & POLLIN != 0 and (p.count > 0 or p.wrefs == 0)) r |= POLLIN;
            if (p.wrefs == 0) r |= POLLHUP;
        },
        .pipe_w => {
            const p = &pipes[@intCast(c.fds[fdi])];
            if (ev & POLLOUT != 0 and p.count < p.buf.len) r |= POLLOUT;
            if (p.rrefs == 0) r |= POLLERR;
        },
        .sock => {
            const v = c.fds[fdi] - 1;
            const pair: usize = @intCast(v >> 1);
            const side: usize = @intCast(v & 1);
            const s = &socks[pair];
            const d = &s.dir[side];
            if (s.conn) {
                if (ev & POLLIN != 0 and
                    (d.count > 0 or s.refs[side ^ 1] == 0)) r |= POLLIN;
                if (ev & POLLOUT != 0 and
                    (d.count < d.buf.len or s.refs[side ^ 1] == 0)) r |= POLLOUT;
                if (s.refs[side ^ 1] == 0) r |= POLLRDHUP | POLLERR;
            }
        },
        .slisten => {
            const l = &listeners[@intCast(c.fds[fdi] - 1)];
            if (ev & POLLIN != 0 and l.npend > 0) r |= POLLIN;
        },
        // a surface accepts a blit at any time — always writable,
        // never readable (it is not a byte channel).
        .surf => r |= ev & POLLOUT,
        .input => {
            if (ev & POLLIN != 0 and koruos_input_pending() != 0) r |= POLLIN;
        },
        .epoll => {
            if (ev & POLLIN != 0 and
                epollReady(c, @intCast(c.fds[fdi] - 1), 0)) r |= POLLIN;
        },
        .efd => {
            const e = &efds[@intCast(c.fds[fdi] - 1)];
            if (ev & POLLIN != 0 and e.val != 0) r |= POLLIN;
            if (ev & POLLOUT != 0 and e.val < EFD_MAX) r |= POLLOUT;
        },
        .tfd => {
            const t = &tfds[@intCast(c.fds[fdi] - 1)];
            tfdPump(t);
            if (ev & POLLIN != 0 and t.count != 0) r |= POLLIN;
        },
        .sfd => {
            const s = &sfds[@intCast(c.fds[fdi] - 1)];
            if (ev & POLLIN != 0 and c.sig_pending & s.mask != 0) r |= POLLIN;
        },
        .none => return POLLNVAL,
    }
    return r;
}

// One readiness pass: fills revents, returns the count of ready fds.
fn pollScan(c: *Child, fdsva: u64, nfds: u64) i64 {
    var nready: i64 = 0;
    var i: usize = 0;
    while (i < nfds) : (i += 1) {
        var pfd: [8]u8 = undefined;
        if (copyFromUser(c, @intCast(fdsva + i * 8), &pfd) < 8) return -14;
        const fdn = std.mem.readInt(i32, pfd[0..4], .little);
        const ev = std.mem.readInt(u16, pfd[4..6], .little);
        var rev: u16 = 0;
        if (fdn >= 0) rev = fdPollRev(c, @intCast(fdn), ev);
        std.mem.writeInt(u16, pfd[6..8], rev, .little);
        if (copyToUser(c, @intCast(fdsva + i * 8), &pfd) < 8) return -14;
        if (rev != 0) nready += 1;
    }
    return nready;
}

// Tick deadline: irq_ticks is the only wall clock the roster shares —
// ~18.2 Hz PIT on the BSP, the LAPIC's calibrated sibling on APs.
// Millisecond timeouts quantize to ~55 ms: honest granularity, stated.
fn pollDeadlineTicks(ms: i64) u64 {
    if (ms <= 0) return 0;
    const t: u64 = @intCast(ms);
    return (t * 100 + 5499) / 5500; // ceil(ms / 55) — PIT quantum
}

fn childPoll(c: *Child, fdsva: u64, nfds: u64, tmo_ms: i64) i64 {
    if (nfds > MAXPOLLFDS) return -22;
    const deadline: u64 = if (tmo_ms < 0) std.math.maxInt(u64)
        else irq_ticks + pollDeadlineTicks(tmo_ms);
    while (true) {
        const n = pollScan(c, fdsva, nfds);
        if (n != 0) return n;
        if (irq_ticks >= deadline) return 0;
        kblock(.poll); // wake = any readiness change or the tick
    }
}

// msghdr on x86_64: {name 8, namelen 4+4, iov 8, iovlen 8, control 8,
// controllen 8, flags 4+4} = 56 bytes. cmsghdr: {len 8, level 4, type 4}.
// We only speak SOL_SOCKET/SCM_RIGHTS ancillary — anything else is
// ignored like a kernel that doesn't know the level.
// msg flags: MSG_DONTWAIT (0x40) makes the byte phase nonblocking —
// libwayland flushes and reads with it — MSG_NOSIGNAL (0x4000) is a
// no-op where SIGPIPE does not exist, MSG_CMSG_CLOEXEC (0x40000000)
// marks received fds exec-close — no exec exists yet, the mark is
// free. Anything else is a flag we don't model: EOPNOTSUPP, loudly.
const MSG_KNOWN: u64 = 0x40 | 0x4000 | 0x40000000;

fn childSendmsg(c: *Child, fdu: u64, mhva: u64, flags: u64) i64 {
    if (flags & ~MSG_KNOWN != 0) return -95;
    const nb = flags & 0x40 != 0;
    if (fdu >= c.fds.len) return -9;
    const fd: usize = @intCast(fdu);
    if (c.fdkinds[fd] != .sock) return -88; // ENOTSOCK
    const pair: usize = @intCast((c.fds[fd] - 1) >> 1);
    const dir: usize = @intCast(((c.fds[fd] - 1) & 1) ^ 1); // write dir
    var mh: [56]u8 = undefined;
    if (copyFromUser(c, @intCast(mhva), &mh) < 56) return -14;
    const iovp = std.mem.readInt(u64, mh[16..24], .little);
    const iovn = std.mem.readInt(u64, mh[24..32], .little);
    const ctlp = std.mem.readInt(u64, mh[32..40], .little);
    const ctln = std.mem.readInt(u64, mh[40..48], .little);
    // Bytes first — stream iovs through the peer ring (blocks on full).
    var total: i64 = 0;
    var i: usize = 0;
    while (i < iovn and i < 64) : (i += 1) {
        var iov: [16]u8 = undefined;
        if (copyFromUser(c, @intCast(iovp + i * 16), &iov) < 16) {
            return if (total > 0) total else -14;
        }
        const base = std.mem.readInt(u64, iov[0..8], .little);
        const len = std.mem.readInt(u64, iov[8..16], .little);
        if (len == 0) continue;
        const n = sockWrite(c, pair, dir, base, len, nb);
        if (n < 0) return if (total > 0) total else n;
        total += n;
        if (n < len) break;
    }
    // Then ancillary: each SCM_RIGHTS cmsg dups its fds into the peer's
    // receive queue — dup-at-send, so the sender closing later changes
    // nothing. Queue full refuses loudly (ENOBUFS).
    var off: usize = 0;
    while (off + 16 <= ctln) {
        var ch: [16]u8 = undefined;
        if (copyFromUser(c, @intCast(ctlp + off), &ch) < 16) break;
        const clen = std.mem.readInt(u64, ch[0..8], .little);
        const level = std.mem.readInt(i32, ch[8..12], .little);
        const ctype = std.mem.readInt(i32, ch[12..16], .little);
        if (clen < 16 or off + clen > ctln) break;
        if (level == 1 and ctype == 1) { // SOL_SOCKET/SCM_RIGHTS
            var p: usize = 16;
            while (p + 4 <= clen) : (p += 4) {
                var ib: [4]u8 = undefined;
                if (copyFromUser(c, @intCast(ctlp + off + p), &ib) < 4) break;
                const sfd: usize = @intCast(std.mem.readInt(i32, ib[0..4], .little));
                if (sfd >= c.fds.len or c.fdkinds[sfd] == .none) return -9;
                const d = &socks[pair].dir[dir];
                if (d.qn >= SOCKQ) return -105; // ENOBUFS — bound is loud
                var ref: FdRef = .{};
                if (!fdDupRef(c, sfd, &ref)) return -9;
                d.q[d.qn] = ref;
                d.qn += 1;
                sock_fdpass += 1;
            }
        }
        off += (clen + 7) & ~@as(usize, 7); // CMSG_ALIGN
    }
    return total;
}

fn childRecvmsg(c: *Child, fdu: u64, mhva: u64, flags: u64) i64 {
    if (flags & ~MSG_KNOWN != 0) return -95;
    const nb = flags & 0x40 != 0;
    if (fdu >= c.fds.len) return -9;
    const fd: usize = @intCast(fdu);
    if (c.fdkinds[fd] != .sock) return -88;
    const pair: usize = @intCast((c.fds[fd] - 1) >> 1);
    const side: usize = @intCast((c.fds[fd] - 1) & 1);
    var mh: [56]u8 = undefined;
    if (copyFromUser(c, @intCast(mhva), &mh) < 56) return -14;
    const iovp = std.mem.readInt(u64, mh[16..24], .little);
    const iovn = std.mem.readInt(u64, mh[24..32], .little);
    const ctlp = std.mem.readInt(u64, mh[32..40], .little);
    const ctln = std.mem.readInt(u64, mh[40..48], .little);
    var total: i64 = 0;
    var i: usize = 0;
    while (i < iovn and i < 64) : (i += 1) {
        var iov: [16]u8 = undefined;
        if (copyFromUser(c, @intCast(iovp + i * 16), &iov) < 16) {
            return if (total > 0) total else -14;
        }
        const base = std.mem.readInt(u64, iov[0..8], .little);
        const len = std.mem.readInt(u64, iov[8..16], .little);
        if (len == 0) continue;
        const n = sockRead(c, pair, side, base, len, nb);
        if (n < 0) return if (total > 0) total else n;
        total += n;
        if (n < len or n == 0) break; // short read or EOS
    }
    // Ancillary: install queued refs into THIS table under a real
    // cmsghdr — only when the caller offered control space (a plain
    // read() leaves them queued for the next recvmsg). Table-full
    // truncates like linux: fit what fits, close the rest, CTRUNC.
    var ctlout: u64 = 0;
    var msgflags: u64 = 0;
    const d = &socks[pair].dir[side];
    if (ctlp != 0 and ctln >= 16 and d.qn > 0) {
        var fds: [SOCKQ]u32 = .{0} ** SOCKQ;
        var got: usize = 0;
        while (d.qn > 0) {
            d.qn -= 1;
            const ref = d.q[d.qn];
            var slot: ?usize = null;
            for (0..c.fds.len) |si| {
                if (c.fdkinds[si] == .none) { slot = si; break; }
            }
            if (slot) |si| {
                c.fdkinds[si] = ref.kind;
                c.fds[si] = ref.h;
                c.fdverbs[si] = ref.verbs;
                fds[got] = @intCast(si);
                got += 1;
            } else {
                fdFreeRef(ref); // nowhere to land — close like linux
                msgflags |= 8; // MSG_CTRUNC
            }
        }
        var ch: [16]u8 = undefined;
        std.mem.writeInt(u64, ch[0..8], 16 + @as(u64, @intCast(got * 4)), .little);
        std.mem.writeInt(i32, ch[8..12], 1, .little); // SOL_SOCKET
        std.mem.writeInt(i32, ch[12..16], 1, .little); // SCM_RIGHTS
        _ = copyToUser(c, @intCast(ctlp), &ch);
        var fb: [SOCKQ * 4]u8 = undefined;
        for (0..got) |gi| std.mem.writeInt(u32, fb[gi * 4 ..][0..4], fds[gi], .little);
        _ = copyToUser(c, @intCast(ctlp + 16), fb[0 .. got * 4]);
        ctlout = (16 + @as(u64, @intCast(got * 4)) + 7) & ~@as(u64, 7); // CMSG_SPACE
    }
    // Report the real controllen/flags back into the caller's msghdr.
    // controllen is size_t at +40; flags is int at +48 — 4 bytes only.
    var ob: [8]u8 = undefined;
    std.mem.writeInt(u64, ob[0..8], ctlout, .little);
    _ = copyToUser(c, @intCast(mhva + 40), &ob);
    std.mem.writeInt(i32, ob[0..4], @intCast(msgflags), .little);
    _ = copyToUser(c, @intCast(mhva + 48), ob[0..4]);
    return total;
}

// nr 319 — memfd_create(name, flags): mint an anonymous shm object.
// Size starts 0; ftruncate gives it shape.
fn childMemfd(c: *Child) i64 {
    var idx: ?usize = null;
    for (0..NSHM) |i| {
        if (!shms[i].used) { idx = i; break; }
    }
    const si = idx orelse return -24;
    var slot: ?usize = null;
    for (0..c.fds.len) |i| {
        if (c.fdkinds[i] == .none) { slot = i; break; }
    }
    const s = slot orelse return -24;
    shms[si] = .{ .used = true, .refs = 1 };
    c.fdkinds[s] = .shm;
    c.fds[s] = si + 1;
    c.fdverbs[s] = V_READ | V_WRITE;
    return @intCast(s);
}

// ---- POSIX shm namespace: /dev/shm/<name> -------------------------------
// musl's shm_open is open("/dev/shm/"+name); shm_unlink is unlink of
// the same path. The name lives ON the shm object, so reopen-by-name
// (wlroots' RW+RO pool pair), cross-process sharing, and unlink-
// while-mapped are all just the object's own lifetime. Path opens
// under the prefix are intercepted before the fs view — the namespace
// IS /dev/shm on this arm; the channel class (22, memfd's bit) covers
// the syscall already since it folds through open().

fn shmNameMatch(s: *const ShmObj, name: []const u8) bool {
    return s.namelen == name.len and
        std.mem.eql(u8, s.name[0..s.namelen], name);
}

fn shmFind(name: []const u8) ?usize {
    for (&shms, 0..) |*s, i| {
        if (s.used and shmNameMatch(s, name)) return i;
    }
    return null;
}

// "/dev/shm/" → rest or null. Names carry no '/' and fit the object.
fn shmPathName(p: []const u8) ?[]const u8 {
    const pre = "/dev/shm/";
    if (p.len <= pre.len or !std.mem.eql(u8, p[0..pre.len], pre)) return null;
    const rest = p[pre.len..];
    if (rest.len > 47 or std.mem.indexOfScalar(u8, rest, '/') != null) return null;
    return rest;
}

fn childShmOpen(c: *Child, name: []const u8, flags: u64) i64 {
    const creat = flags & 0o100 != 0;
    const excl = flags & 0o200 != 0;
    const trunc = flags & 0o1000 != 0;
    var si: ?usize = shmFind(name);
    if (si != null and creat and excl) return -17; // EEXIST
    if (si == null) {
        if (!creat) return -2; // ENOENT
        for (&shms, 0..) |*s, i| if (!s.used) {
            s.* = .{ .used = true, .refs = 1 };
            @memcpy(s.name[0..name.len], name);
            s.namelen = @intCast(name.len);
            si = i;
            break;
        };
        if (si == null) return -24;
    } else {
        shms[si.?].refs += 1;
        if (trunc) _ = shmTrunc(si.?, 0);
    }
    var slot: ?usize = null;
    for (0..c.fds.len) |i| {
        if (c.fdkinds[i] == .none) { slot = i; break; }
    }
    const fdi = slot orelse {
        shmRelease(si.?);
        return -24;
    };
    c.fdkinds[fdi] = .shm;
    c.fds[fdi] = si.? + 1;
    const mode: u8 = @intCast(flags & 3);
    c.fdverbs[fdi] = switch (mode) {
        0 => V_READ,
        1 => V_WRITE,
        else => V_READ | V_WRITE,
    };
    return @intCast(fdi);
}

fn childShmUnlink(name: []const u8) i64 {
    const si = shmFind(name) orelse return -2;
    shms[si].namelen = 0; // the NAME dies; refs keep the object
    return 0;
}

// nr 91 — fchmod(fd, mode): mode bits live on shm objects (the pair
// locks its rw side to 0 — we store, fstat reports). Other kinds have
// no mutable mode — ENOSYS says so rather than lying about success.
fn childFchmod(c: *Child, fdu: u64, mode: u64) i64 {
    if (fdu >= c.fds.len) return -9;
    const fd: usize = @intCast(fdu);
    if (c.fdkinds[fd] != .shm) return -38;
    if (mode & ~@as(u64, 0o7777) != 0) return -22;
    shms[@intCast(c.fds[fd] - 1)].mode = @intCast(mode);
    return 0;
}

// nr 77 — ftruncate(fd, len): only shm objects take a size.
fn childFtruncate(c: *Child, fdu: u64, len: u64) i64 {
    if (fdu >= c.fds.len) return -9;
    const fd: usize = @intCast(fdu);
    if (c.fdkinds[fd] != .shm) return -22;
    return shmTrunc(@intCast(c.fds[fd] - 1), len);
}

// nr 61 — wait(pid, status): pid is the pid-domain id spawn_start/fork
// handed back (slot+1; slots are internal, 0 is never a pid). -1 waits
// for ANY zombie. Reaping marks the slot .dead: the status is claimed
// once and a reused slot can never serve it twice.
const ANY_PID: usize = ~@as(usize, 0);
fn childWait(c: *Child, pid: i64, stva: u64) i64 {
    while (true) {
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
    nc.spawned_by = cur_child; // the spawner is the SIGCHLD parent
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
        const st = children[g].state;
        if (st == .dead or st == .zombie) break;
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
    nc.spawned_by = cur_child; // fork's child reports its death upward
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
    nc.sig_blocked = c.sig_blocked; // posix: the mask inherits, pending
                                  // does not — sigs stay empty
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
    lockBkl(); // the body owns the roster lock; escapes release it by name
    defer unlockBkl();
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
                    .sock => f.rax = @bitCast(sockWrite(c, @intCast((c.fds[fdi] - 1) >> 1), @intCast(((c.fds[fdi] - 1) & 1) ^ 1), f.rsi, f.rdx, false)),
                    // The fd is the grant: a write verb was minted at
                    // open or this projection never carried one — EBADF,
                    // the POSIX refusal for a bad-mode write.
                    .fs => f.rax = @bitCast(if (c.fdverbs[fdi] & V_WRITE != 0)
                        childWrite(c, fdi, f.rsi, f.rdx) else -9),
                    .efd => f.rax = @bitCast(childEfdWrite(c, f)),
                    .tfd => f.rax = @bitCast(@as(i64, -22)), // EINVAL — a clock has no write end
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
                        .sock => {
                            const v = c.fds[fdi] - 1;
                            const n = sockWrite(c, @intCast(v >> 1), @intCast((v & 1) ^ 1), @intCast(base), @intCast(len), false);
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
        515 => { // surf_open(w, h) — mint a display surface, project as fd
            f.rax = @bitCast(childSurfOpen(c, f));
        },
        516 => { // surf_blit(fd, src_va, stride, rect_va) — commit write
            f.rax = @bitCast(childSurfBlit(c, f));
        },
        517 => { // surf_present(fd, x, y, w, h) — damage through the scene
            f.rax = @bitCast(childSurfPresent(c, f));
        },
        518 => { // input_open() — evdev-shaped door onto the input rings
            f.rax = @bitCast(childInputOpen(c));
        },
        519 => { // surf_move(fd, x, y) — compositor placement
            f.rax = @bitCast(childSurfMove(c, f));
        },
        520 => { // surf_info(fd, rect_va) — surface rect + scene extent
            f.rax = @bitCast(childSurfInfo(c, f));
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
                     // routes to the rmdir verb (musl's rmdir(2) lands
                     // here — unlink on a dir is EISDIR, never a merge).
            if (f.rax == 263 and (f.rdx & 0x200) != 0) {
                if (f.rdi != @as(u64, @bitCast(@as(i64, -100)))) {
                    f.rax = @bitCast(@as(i64, -9)); // only AT_FDCWD has meaning
                } else {
                    f.rax = @bitCast(childRmdir(c, @intCast(f.rsi)));
                }
            } else if (f.rax == 263 and
                       f.rdi != @as(u64, @bitCast(@as(i64, -100)))) {
                f.rax = @bitCast(@as(i64, -9));
            } else {
                const pva: usize = if (f.rax == 87) @intCast(f.rdi) else @intCast(f.rsi);
                f.rax = @bitCast(childUnlink(c, pva));
            }
        },
        83, 258 => { // mkdir / mkdirat — mints a dir object; only
                     // AT_FDCWD is meaningful (no dirfd views exist).
            if (f.rax == 258 and f.rdi != @as(u64, @bitCast(@as(i64, -100)))) {
                f.rax = @bitCast(@as(i64, -9));
            } else {
                const pva: usize = if (f.rax == 83) @intCast(f.rdi) else @intCast(f.rsi);
                f.rax = @bitCast(childMkdir(c, pva));
            }
        },
        84 => { // rmdir — removes an EMPTY directory name
            f.rax = @bitCast(childRmdir(c, @intCast(f.rdi)));
        },
        86, 265 => { // link / linkat — a second name on the same inode;
                     // flags must be 0 (no AT_SYMLINK_FOLLOW/EMPTY_PATH).
            if (f.rax == 265 and
                (f.rdi != @as(u64, @bitCast(@as(i64, -100))) or
                 f.rdx != @as(u64, @bitCast(@as(i64, -100))) or f.r8 != 0)) {
                f.rax = @bitCast(if (f.r8 != 0) @as(i64, -38) else -9);
            } else {
                const ova: usize = if (f.rax == 86) @intCast(f.rdi) else @intCast(f.rsi);
                const nva: usize = if (f.rax == 86) @intCast(f.rsi) else @intCast(f.r10);
                f.rax = @bitCast(childLink(c, ova, nva));
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
                    .input => childInputRead(c, f),
                    .efd => childEfdRead(c, f),
                    .tfd => childTfdRead(c, f),
                    .sfd => childSfdRead(c, f),
                    .conin => coninRead(c, f),
                    .fs => if (c.fdverbs[fdi] & V_READ != 0)
                        childRead(c, f.rdi, f.rsi, f.rdx) else -9,
                    .pipe_r => pipeReadEnd(c, @intCast(c.fds[fdi]), f.rsi, f.rdx),
                    .sock => sockRead(c, @intCast((c.fds[fdi] - 1) >> 1), @intCast((c.fds[fdi] - 1) & 1), f.rsi, f.rdx, false),
                    else => @as(i64, -9),
                });
            }
        },
        22 => { // pipe(fds[2]) — mints a ring; endpoints land as pipe_r/
                // pipe_w entries in the caller's projection.
            f.rax = @bitCast(childPipe(c, f.rdi));
        },
        53 => { // socketpair(domain, type, protocol, sv[2]) — AF_UNIX
                // SOCK_STREAM only: the stream shape wayland's wire needs.
                // Other domains/types refuse by class, not by silence.
            if (f.rdi != 1 or (f.rsi & 0xF) != 1) {
                f.rax = @bitCast(@as(i64, -97)); // EAFNOSUPPORT
            } else {
                f.rax = @bitCast(childSocketpair(c, f.r10));
            }
        },
        41 => { // socket(domain, type, protocol) — an unconnected end
            f.rax = @bitCast(childSocket(c, f));
        },
        49 => { // bind(fd, sockaddr_un, len) — name the end in the fs view
            f.rax = @bitCast(childBind(c, f));
        },
        50 => { // listen(fd, backlog) — open the node's session queue
            f.rax = @bitCast(childListen(c, f));
        },
        42 => { // connect(fd, sockaddr_un, len) — resolve the name, queue
                // a session end on its listener, take the client end
            f.rax = @bitCast(childConnect(c, f));
        },
        43, 288 => { // accept/accept4(fd, addr, addrlen[, flags]) — pop a
                     // pending session end into a new projection; the
                     // addr out-params are caller's choice, flags are
                     // the fcntl no-ops
            f.rax = @bitCast(childAccept(c, f));
        },
        46 => { // sendmsg(fd, msghdr, flags) — iov bytes + SCM_RIGHTS;
                // MSG_DONTWAIT flushes EAGAIN rather than parking.
            f.rax = @bitCast(childSendmsg(c, f.rdi, f.rsi, f.rdx));
        },
        47 => { // recvmsg(fd, msghdr, flags) — bytes + queued fd install;
                // MSG_DONTWAIT reads EAGAIN rather than parking.
            f.rax = @bitCast(childRecvmsg(c, f.rdi, f.rsi, f.rdx));
        },
        319 => { // memfd_create(name, flags) — an anonymous shm object;
                 // the pool fd wl_shm sends. name is diagnostic only.
            f.rax = @bitCast(childMemfd(c));
        },
        7 => { // poll(fds, nfds, timeout_ms) — readiness multiplex over
               // the typed projection; .poll continuation, tick deadlines.
            const ms: i64 = @as(i32, @bitCast(@as(u32, @truncate(f.rdx))));
            f.rax = @bitCast(childPoll(c, f.rdi, f.rsi, ms));
        },
        271 => { // ppoll(fds, nfds, ts, mask) — the atomic mask swap
                 // is about async delivery, which doesn't exist here
                 // (queued facts only); NULL mask is the only honest
                 // shape, which is the only shape libwayland sends.
            if (f.r10 != 0) {
                f.rax = @bitCast(@as(i64, -38)); // ENOSYS — sigmask swap
            } else {
                var ms: i64 = -1;
                var bad: i64 = 0;
                if (f.rdx != 0) {
                    var ts: [16]u8 = undefined;
                    if (copyFromUser(c, @intCast(f.rdx), &ts) < 16) {
                        bad = -14;
                    } else {
                        const sec = std.mem.readInt(i64, ts[0..8], .little);
                        const nsec = std.mem.readInt(i64, ts[8..16], .little);
                        if (sec < 0 or nsec < 0 or nsec >= 1_000_000_000) {
                            bad = -22;
                        } else {
                            ms = std.math.mul(i64, sec, 1000) catch std.math.maxInt(i64);
                            ms = std.math.add(i64, ms, @divTrunc(nsec + 999_999, 1_000_000)) catch std.math.maxInt(i64);
                        }
                    }
                }
                f.rax = @bitCast(if (bad != 0) bad else childPoll(c, f.rdi, f.rsi, ms));
            }
        },
        213, 291 => { // epoll_create(size)/epoll_create1(flags) — the
                      // interest-list object; flags carry CLOEXEC which
                      // means nothing until an exec keeps the table
            f.rax = @bitCast(childEpollCreate(c));
        },
        233 => { // epoll_ctl(epfd, op, fd, event) — interest-list verbs
            f.rax = @bitCast(childEpollCtl(c, f.rdi, f.rsi, f.rdx, f.r10));
        },
        232, 281 => { // epoll_wait/epoll_pwait(epfd, events, maxevents,
                      // timeout [, sigmask, sigsetsize]) — musl issues
                      // the pwait nr for plain epoll_wait; the mask arg
                      // is inert — facts queue, nothing interrupts
            const ms: i64 = @as(i32, @bitCast(@as(u32, @truncate(f.r10))));
            f.rax = @bitCast(childEpollWait(c, f.rdi, f.rsi, f.rdx, ms));
        },
        284, 290 => { // eventfd(initval)/eventfd2(initval, flags) — a
                      // counted semaphore as an fd; terminate_efd is one
            f.rax = @bitCast(childEventfd(c, f.rdi, if (f.rax == 290) f.rsi else 0));
        },
        283 => { // timerfd_create(clockid, flags) — a time-shaped channel
            f.rax = @bitCast(childTimerfdCreate(c, f.rdi, f.rsi));
        },
        286 => { // timerfd_settime(fd, flags, new, old) — arm/disarm
            f.rax = @bitCast(childTimerfdSettime(c, f.rdi, f.rsi, f.rdx, f.r10));
        },
        287 => { // timerfd_gettime(fd, cur) — remaining + interval
            f.rax = @bitCast(childTimerfdGettime(c, f.rdi, f.rsi));
        },
        282, 289 => { // signalfd/signalfd4(fd, mask, sizemask, flags) —
                      // the pending queue as a channel; 282 has no size/
                      // flags words; the 4-arg form's sizemask must be
                      // the honest 8 like linux validates.
            f.rax = @bitCast(if (f.rax == 289 and f.rdx != 8)
                @as(i64, -22)
            else
                childSignalfd(c, f.rdi, f.rsi,
                    if (f.rax == 289) f.r10 else 0));
        },
        91 => { // fchmod(fd, mode) — mode bits on objects that carry them
            f.rax = @bitCast(childFchmod(c, f.rdi, f.rsi));
        },
        73 => { // flock(fd, op) — advisory locks on object identity;
                // wl_socket_lock's compositor-contention check rides it
            f.rax = @bitCast(childFlock(c, f.rdi, f.rsi));
        },
        4, 6 => { // stat/lstat(path, st) — no symlink layer; identical
            f.rax = @bitCast(childStatPath(c, @intCast(f.rdi), f.rsi));
        },
        21 => { // access(path, mode)
            f.rax = @bitCast(childAccess(c, @intCast(f.rdi), f.rsi, 0));
        },
        269 => { // faccessat(dfd, path, mode) — no cwd model; AT_FDCWD
                 // shape only, relative paths resolve from the view root
            f.rax = @bitCast(childAccess(c, @intCast(f.rsi), f.rdx, 0));
        },
        439 => { // faccessat2(dfd, path, mode, flags)
            f.rax = @bitCast(childAccess(c, @intCast(f.rsi), f.rdx, f.r10));
        },
        55 => { // getsockopt(fd, level, optname, optval, optlen)
            f.rax = @bitCast(childGetsockopt(c, f));
        },
        77 => { // ftruncate(fd, len) — sizes shm objects (grow, zero)
            f.rax = @bitCast(childFtruncate(c, f.rdi, f.rsi));
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
                        const ofd = ofdOf(c, fd);
                        if (c.fsv) |ops| _ = ops.close(ops.ctx, c.fds[fd]);
                        c.fds[fd] = 0;
                        c.fdkinds[fd] = .none;
                        flockDropIfOrphaned(c, ofd);
                        f.rax = 0;
                    },
                    .pipe_r, .pipe_w => {
                        pipeCloseEnd(@intCast(c.fds[fd]), had);
                        c.fds[fd] = 0;
                        c.fdkinds[fd] = .none;
                        f.rax = 0;
                    },
                    .sock => {
                        sockCloseEnd(@intCast((c.fds[fd] - 1) >> 1), @intCast((c.fds[fd] - 1) & 1));
                        c.fds[fd] = 0;
                        c.fdkinds[fd] = .none;
                        f.rax = 0;
                    },
                    .slisten => {
                        listenerRelease(@intCast(c.fds[fd] - 1));
                        c.fds[fd] = 0;
                        c.fdkinds[fd] = .none;
                        f.rax = 0;
                    },
                    .shm => {
                        const ofd = ofdOf(c, fd);
                        shmRelease(@intCast(c.fds[fd] - 1));
                        c.fds[fd] = 0;
                        c.fdkinds[fd] = .none;
                        flockDropIfOrphaned(c, ofd);
                        f.rax = 0;
                    },
                    .surf => { // close is the surface's release verb —
                              // last ref detaches; comp repaints the
                              // vacated rect from lower backings.
                        surfRefFree(@intCast(c.fds[fd] - 1));
                        c.fds[fd] = 0;
                        c.fdkinds[fd] = .none;
                        f.rax = 0;
                    },
                    .input => {
                        inputFree(@intCast(c.fds[fd] - 1));
                        c.fds[fd] = 0;
                        c.fdkinds[fd] = .none;
                        f.rax = 0;
                    },
                    .epoll => {
                        epollFree(@intCast(c.fds[fd] - 1));
                        c.fds[fd] = 0;
                        c.fdkinds[fd] = .none;
                        f.rax = 0;
                    },
                    .efd => {
                        efdFree(@intCast(c.fds[fd] - 1));
                        c.fds[fd] = 0;
                        c.fdkinds[fd] = .none;
                        f.rax = 0;
                    },
                    .tfd => {
                        tfdFree(@intCast(c.fds[fd] - 1));
                        c.fds[fd] = 0;
                        c.fdkinds[fd] = .none;
                        f.rax = 0;
                    },
                    .sfd => {
                        sfdFree(@intCast(c.fds[fd] - 1));
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
        14 => { // rt_sigprocmask(how, set, oldset, size) — the block set
                // is real state: wl_event_loop_add_signal blocks before
                // signalfd, and the recorded mask is the loop's promise
                // to consume the queue through the fd. No async delivery
                // exists to race — stored, consulted by nothing but the
                // next oldset read.
            var ret: i64 = 0;
            if (f.rdx != 0) {
                var ob: [8]u8 = undefined;
                std.mem.writeInt(u64, &ob, c.sig_blocked, .little);
                if (copyToUser(c, @intCast(f.rdx), &ob) < 8) ret = -14;
            }
            if (ret == 0 and f.rsi != 0) {
                var ib: [8]u8 = undefined;
                if (copyFromUser(c, @intCast(f.rsi), &ib) < 8) {
                    ret = -14;
                } else {
                    const m = std.mem.readInt(u64, &ib, .little);
                    switch (f.rdi) {
                        0 => c.sig_blocked |= m,  // SIG_BLOCK
                        1 => c.sig_blocked &= ~m, // SIG_UNBLOCK
                        2 => c.sig_blocked = m,   // SIG_SETMASK
                        else => ret = -22,
                    }
                }
            }
            f.rax = @bitCast(ret);
        },
        13 => { // rt_sigaction — wl_shm's SIGBUS guard installs/restores a
                // handler around each shm access. No kill, no SIGBUS (our
                // eager map faults at copy time) — a registered handler
                // that can never fire is the truthful shape. oldact gets
                // SIG_DFL, the honest current disposition.
            if (f.rdx != 0) _ = copyToUser(c, @intCast(f.rdx), &[_]u8{0} ** 32);
            f.rax = 0;
        },
        39, 186 => { // getpid / gettid — the pid domain is slot+1; one
                     // thread per child exists, so tid IS pid here.
            f.rax = @intCast(cur_child + 1);
        },
        72 => { // fcntl(fd, cmd, arg) — flag ops are honest no-ops (no
                // exec exists for CLOEXEC to matter, O_NONBLOCK rides
                // per-call flags instead of fd state), but F_DUPFD is a
                // REAL dup: libwayland undup()s SCM_RIGHTS arrivals
                // through it and a stub would hand back fd 0.
            if (f.rdi >= c.fds.len or c.fdkinds[@intCast(f.rdi)] == .none) {
                f.rax = @bitCast(@as(i64, -9));
            } else if (f.rsi == 6 or f.rsi == 1030) { // F_DUPFD[/_CLOEXEC]
                if (f.rdx >= c.fds.len) {
                    f.rax = @bitCast(@as(i64, -22)); // EINVAL past the ceiling
                } else {
                    var slot: ?usize = null;
                    for (@intCast(f.rdx)..c.fds.len) |si| {
                        if (c.fdkinds[si] == .none) { slot = si; break; }
                    }
                    if (slot) |si| {
                        _ = cloneFd(c, si, c, @intCast(f.rdi));
                        f.rax = @intCast(si);
                    } else {
                        f.rax = @bitCast(@as(i64, -24)); // EMFILE
                    }
                }
            } else if (f.rsi == 3) { // F_GETFL — access mode from the
                // projection's verbs; status flags don't exist here.
                const v = c.fdverbs[@intCast(f.rdi)];
                f.rax = @bitCast(@as(i64, if (v & V_READ != 0 and v & V_WRITE != 0) 2
                    else if (v & V_WRITE != 0) 1 else 0));
            } else if (f.rsi <= 4) { // F_GETFD/F_SETFD/F_SETFL — success
                f.rax = 0;
            } else {
                f.rax = @bitCast(@as(i64, -22)); // EINVAL — unknown cmd
            }
        },
        32 => { // dup(fd) — lowest free slot, same projection
            if (f.rdi >= c.fds.len or c.fdkinds[@intCast(f.rdi)] == .none) {
                f.rax = @bitCast(@as(i64, -9));
            } else {
                var slot: ?usize = null;
                for (0..c.fds.len) |si| {
                    if (c.fdkinds[si] == .none) { slot = si; break; }
                }
                if (slot) |si| {
                    _ = cloneFd(c, si, c, @intCast(f.rdi));
                    f.rax = @intCast(si);
                } else {
                    f.rax = @bitCast(@as(i64, -24));
                }
            }
        },
        33, 292 => { // dup2(fd,newfd) / dup3(fd,newfd,flags) — exact slot:
                     // close what sat there, project the source onto it.
            const oldfd = f.rdi;
            const newfd = f.rsi;
            if (oldfd >= c.fds.len or c.fdkinds[@intCast(oldfd)] == .none or
                newfd >= c.fds.len)
            {
                f.rax = @bitCast(@as(i64, -9));
            } else if (f.rax == 292 and oldfd == newfd) {
                f.rax = @bitCast(@as(i64, -22)); // dup3 forbids same fd
            } else {
                if (oldfd == newfd) {
                    f.rax = @intCast(newfd); // dup2's no-op answer
                } else {
                    if (c.fdkinds[@intCast(newfd)] != .none)
                        releaseFd(c, @intCast(newfd));
                    _ = cloneFd(c, @intCast(newfd), c, @intCast(oldfd));
                    f.rax = @intCast(newfd);
                }
            }
        },
        228 => { // clock_gettime(id, ts) — the calibrated TSC is the only
                 // clock we hold: MONOTONIC is its native reading;
                 // REALTIME gets the same count (no RTC epoch exists —
                 // time-since-boot is honest where a wall clock isn't).
            const tsva = f.rsi;
            if (f.rdi > 7 or tsva == 0) {
                f.rax = @bitCast(@as(i64, -22));
            } else {
                const ns = ukplat_monotonic_clock();
                var tsb: [16]u8 = undefined;
                std.mem.writeInt(i64, tsb[0..8], @intCast(ns / 1_000_000_000), .little);
                std.mem.writeInt(i64, tsb[8..16], @intCast(ns % 1_000_000_000), .little);
                f.rax = @bitCast(if (copyToUser(c, @intCast(tsva), &tsb) < 16)
                    @as(i64, -14) else 0);
            }
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
            // SIGCHLD — the first honest producer: the spawner's queue
            // gets the death fact whether or not it ever reads it. Only
            // a live slot carries a queue (runnable/blocked/zombie —
            // .dead is free for reuse, .empty never ran).
            {
                const db = children[dead_slot].spawned_by;
                if (db < nchildren and db != dead_slot) {
                    const p = &children[db];
                    if (p.state == .runnable or p.state == .blocked or
                        p.state == .zombie) {
                        sigQueue(p, .{ .signo = SIGCHLD,
                            .code = CLD_EXITED,
                            .pid = @intCast(dead_slot + 1),
                            .status = @intCast(last_exit) });
                        wakeKind(.poll); // the fact lands while a reader
                                         // parks on the queue's fd
                    }
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
            // The dead child's claim lapses — whichever cpu's schedLoop
            // the rotation names next picks up the roster; if the roster
            // drained, THIS cpu escapes back into the spawn caller (the
            // saved stack is shared memory — the continuation is
            // cpu-agnostic, so last-exit-on-AP is a lawful migration).
            // Hop off the dead child's kstack first — releaseExec's kick
            // wakes a designee that may reuse this slot's stack.
            schedEnter(&exitTail);
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
    @memcpy(tss[cpuSelf()][4..12], std.mem.asBytes(&ktop));
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
// returned into; anything else is a saved user frame. The caller holds
// bkl + exec_cpu: the kctx arm KEEPS the lock (the popped continuation
// returns into a syscall body that expects it); the user-resume arm
// drops it — user code runs under the claim alone.
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
    unlockBkl();
    resumeChild(n);
}

// The scheduler loop on whatever kernel stack it was entered on — and it
// is EVERY roster member's idle: APs enter it from apMain, the BSP from
// spawn/ksched/exit. One iteration under bkl: if the user claim is free
// and this cpu is the designated claimant (or the designee is gone),
// claim + switchInto; else drop the lock and sti;hlt — the resched IPI
// or the local tick re-polls. grace is the starvation bound: a hinted
// cpu that never converges is bypassed after ~40 local wakes (bounded,
// only reachable if an online cpu wedges — the roster can't express one).
fn schedLoop() noreturn {
    asm volatile ("sti" ::: .{ .memory = true });
    var grace: u64 = 0;
    while (true) {
        lockBkl();
        if (nextRunnable()) |n| {
            if (!sched_active) {
                // Epoch closed: a runnable slot with a live kctx is a
                // parked SPAWN CALLER (mid-prime device wait hitchhikes
                // on a child slot) — resume it in place, no claim: it
                // returns into kernel code, not user space. A real child
                // (kctx==0) waits for the epoch to open.
                if (children[n].kctx != 0) switchInto(n);
            } else if (exec_cpu == -1) {
                const me = cpuSelf();
                const hinted = exec_hint == me or !smp.rosterHas(exec_hint);
                grace +%= 1;
                if (hinted or grace > 40) {
                    exec_cpu = @intCast(me);
                    exec_hint = smp.nextOnlineAfter(@intCast(me));
                    if (me != 0) {
                        say("sched: slot");
                        koru_putdec(n);
                        say(" claimed by cpu");
                        koru_putdec(me);
                        say("\n");
                    }
                    switchInto(n); // noreturn — user arm drops bkl itself
                }
            }
        } else grace = 0;
        unlockBkl();
        asm volatile (
            \\ sti
            \\ hlt
            ::: .{ .memory = true });
    }
}

// The AP's idle — smp.zig's apMain ends here. Same loop as the BSP's:
// poll the claim, run children when the rotation names this cpu.
export fn koru_sched_idle() callconv(.c) noreturn {
    schedEnter(&schedLoop);
}

// kblock's continuation point: koru_kblock (asm) pushed the callee-saved
// block on this child's kstack and handed us its rsp; record it and
// enter the scheduler — via the sched stack FIRST: releaseExec's kick
// wakes the designee, which may resume THIS kstack while we'd still be
// standing on it. The mark (state/wait_kind) happened under bkl in the
// caller; releaseExec publishes it once we're off the borrowed stack.
export fn ksched(saved: u64) callconv(.c) noreturn {
    children[cur_child].kctx = saved;
    schedEnter(&kschedTail);
}

fn kschedTail() noreturn {
    releaseExec();
    schedLoop();
}

// Exit's sched-stack tail: leave the dead child's address space BEFORE
// the claim frees — the freed pml4 frame can be reallocated as soon as
// another cpu allocates, and the drain/kick window mustn't run on it.
fn exitTail() noreturn {
    asm volatile (
        \\ mov %[cr3], %%rax
        \\ mov %%rax, %%cr3
        :
        : [cr3] "r" (@intFromPtr(&pml4))
        : .{ .memory = true });
    releaseExec();
    if (anyLive()) schedLoop(); // runnable or parked — keep the epoch
    asm volatile (
        \\ mov saved_rsp(%%rip), %%rsp
        \\ jmp *saved_rip(%%rip)
        ::: .{ .memory = true });
    unreachable;
}

// Park the running child mid-call on `kind`: the caller has already
// rechecked its wait condition under bkl; we mark, save kernel context,
// and schedule. Returns on this same stack when a waker flips us
// runnable — the resumed continuation re-holds bkl (the kctx arm keeps
// it) and caller-saved is dead, like any call. Contract: hold bkl so the
// mark can't race the wait condition on ANY cpu.
fn kblock(kind: WaitKind) void {
    const c = &children[cur_child];
    c.wait_kind = kind;
    c.state = .blocked;
    koru_kblock();
    c.wait_kind = .none;
}

// Wake every child blocked on `kind` — the resumed continuation
// re-decides, so waking is always just a mark, never surgery. If no cpu
// holds the user claim, the field is parked in hlt — kick the designee.
fn wakeKind(kind: WaitKind) void {
    if (!sched_active) return;
    var marked = false;
    for (0..nchildren) |i| {
        const c = &children[i];
        // .poll waiters re-decide on EVERY wake — a multiplexed wait
        // names no single key, so any readiness change is potentially
        // theirs. Spurious resume is legal: the loop re-evaluates.
        if (c.state == .blocked and
            (c.wait_kind == kind or c.wait_kind == .poll))
        {
            c.state = .runnable;
            marked = true;
        }
    }
    if (marked and exec_cpu == -1 and smp.rosterHas(exec_hint))
        smp.kickCpu(exec_hint);
}

// virtio's parkOnce calls here when a request can't complete yet: in a
// live epoch the wait is a real block (yield to the roster); outside one
// there is no schedulable context and the caller keeps its hlt path.
// Returns nonzero if it blocked-and-woke. Called with IF=0; returns IF=1.
// kind selects the WaitKind — one seam, not an extern per device:
// 0=blk, 1=gpu, 2=blkq (mirror of WaitKind's device arms).
export fn koru_dev_sleep(kind: u8) callconv(.c) c_int {
    if (!sched_active or nchildren == 0) return 0;
    const k: WaitKind = switch (kind) {
        0 => .blk,
        1 => .gpu,
        2 => .blkq,
        else => return 0,
    };
    kblock(k);
    return 1;
}

// virtio releases its submit mutex by waking whoever queued on .blkq —
// same seam as the sleep side so devices never reach into wakeKind.
export fn koru_dev_wake(kind: u8) callconv(.c) void {
    const k: WaitKind = switch (kind) {
        0 => .blk,
        1 => .gpu,
        2 => .blkq,
        else => return,
    };
    wakeKind(k);
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
// save block) once all children are primed — STILL UNDER the caller's bkl,
// so schedLoop's lock would self-deadlock. Instead take the BSP's own
// claim here (exec_hint starts at the BSP by construction), hand the lock
// off through the normal release, and run the first runnable. The lock
// ownership transfers — spawn_run's tail after `1:` runs unlocked.
export fn sched_launch() callconv(.c) noreturn {
    const me = cpuSelf();
    exec_cpu = @intCast(me);
    exec_hint = smp.nextOnlineAfter(@intCast(me));
    const n = nextRunnable() orelse {
        // an all-dead roster must never reach here — fall back to the
        // blocked caller rather than hang
        unlockBkl();
        asm volatile (
            \\ mov saved_rsp(%%rip), %%rsp
            \\ jmp *saved_rip(%%rip)
            ::: .{ .memory = true });
        unreachable;
    };
    unlockBkl(); // user code holds no lock — the claim carries it
    resumeChild(n);
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
    // The roster mutates while other cpus' schedLoops read it — the whole
    // prime is a locked stretch (a mid-prime park releases and resumes
    // it). No defer: sched_launch CONSUMES the lock, and the drained-epoch
    // tail after `1:` correctly runs without it.
    lockBkl();
    if (n == 0) {
        unlockBkl();
        return 0;
    }
    if (n > MAXCHILDREN) {
        say("RING3 FAIL: roster over MAXCHILDREN\n");
        unlockBkl();
        return -3;
    }
    nchildren = 0;
    for (0..n) |i| {
        const c = &children[i];
        if (!buildTables(c)) {
            say("RING3 FAIL: page alloc\n");
            unlockBkl();
            return -1;
        }
        c.fsv = fsv;
        c.fds = .{0} ** 32;
        // provider children get the stdio projection too — stdio is a
        // typed entry now, not an fd-number special case
        c.fdkinds = .{ .conin, .conout, .conout } ++ .{.none} ** 29;
        c.fdverbs = .{ V_READ, V_WRITE, V_WRITE } ++ .{0} ** 29;
        var ipath: [256]u8 = undefined;
        var ilen: usize = 0;
        const info = loadElf(c, imgs[i][0..sizes[i]], USER_VA_BASE, &ipath, &ilen) orelse {
            say("ELF LOAD FAIL\n");
            unlockBkl();
            return -2;
        };
        var entry = info.entry;
        var at_base: u64 = 0;
        if (ilen > 0) { // PT_INTERP — resolve the loader through the fs view
            if (c.fsv == null) {
                say("ELF REFUSE: PT_INTERP needs an fs view\n");
                unlockBkl();
                return -2;
            }
            const iname = std.mem.sliceTo(ipath[0..ilen], 0);
            const iinfo = loadElfViaFs(c, iname, INTERP_BASE, null, null) orelse {
                say("ELF REFUSE: PT_INTERP loader unreadable\n");
                unlockBkl();
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
        c.frame.rsp = buildStack(c, info, at_base, std.mem.sliceTo(child_arg0[0..], 0)) orelse {
            unlockBkl();
            return -1;
        };
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
        // The epoch opens only once the drain-escape exists — an exit on
        // ANY cpu may run the saved_rsp jump, so the hatch must precede
        // the open flag.
        \\ movb $1, sched_active(%%rip)
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

// No-disk evidence path: spawn the embedded child once per roster slot —
// four copies on one epoch. Under -smp 4 the designated claim rotation
// hands each cpu a child in turn; on uniprocessor the BSP runs all four.
pub fn run() void {
    var imgs = [_][*]const u8{ &child_elf, &child_elf, &child_elf, &child_elf };
    var szs = [_]usize{ child_elf.len, child_elf.len, child_elf.len, child_elf.len };
    var rts = [_]u64{ (1 << 1) | (1 << 60), (1 << 1) | (1 << 60), (1 << 1) | (1 << 60), (1 << 1) | (1 << 60) };
    const st = koru_spawn_run(&imgs, &szs, &rts, 4, null);
    say("EMBED SPAWN exit=");
    puthex(@intCast(@as(u32, @bitCast(st))));
    say("\n");
}
