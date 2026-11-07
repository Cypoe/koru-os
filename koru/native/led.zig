// koru/native/led — keyboard-LED beacon channel. Survives display death:
// the 8042 LED outputs are independent of whatever the panel scans.
// Protocol (see session/m0-i915/NOTES.md):
//   num (0x02)   = kernel alive, latched from kmain
//   caps (0x04)  = blinks once per i915 stage() marker
//   scroll(0x01) = latched at MODESET DONE
//   0x07 all     = exception/panic freeze indicator

fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
        : .{ .memory = true });
}
fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
        : .{ .memory = true });
}
extern fn ukplat_monotonic_clock() callconv(.c) u64; // ns

fn kbcDrain() void {
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        if (inb(0x64) & 0x01 == 0) break;
        _ = inb(0x60);
    }
}
fn kbcWaitIbf() void {
    var i: usize = 0;
    while (inb(0x64) & 0x02 != 0) : (i += 1) {
        if (i > 1_000_000) return;
    }
}
fn kbcCmd(c: u8) void {
    kbcWaitIbf();
    outb(0x64, c);
}
fn kbcDat(d: u8) void {
    kbcWaitIbf();
    outb(0x60, d);
}
fn kbcAck() void {
    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        if (inb(0x64) & 0x01 != 0 and inb(0x60) == 0xFA) return;
    }
}

pub fn set(mask: u8) void {
    kbcDrain();
    kbcCmd(0xED); // set LEDs
    kbcAck();
    kbcDat(mask); // bit0 scroll, bit1 num, bit2 caps
    kbcAck();
}

// caps blink ~120ms on / 120ms off — readable at arm's length.
pub fn blink() void {
    const t0 = ukplat_monotonic_clock();
    set(0x06); // num stays latched + caps on
    while (ukplat_monotonic_clock() - t0 < 120_000_000) {}
    set(0x02); // caps off, num stays
    while (ukplat_monotonic_clock() - t0 < 240_000_000) {}
}

pub fn crash() void {
    set(0x07); // all three solid = frozen fault indicator
}
